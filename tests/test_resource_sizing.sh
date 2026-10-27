#!/bin/bash
# Unit tests for scripts/lib/resource_sizing.sh (the pure sizing model and load()).
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/lib.sh"
source "$HERE/../scripts/lib/resource_sizing.sh"

# Loads a sizing into an associative array `S`.
size() {
    local line; declare -gA S=()
    while IFS='=' read -r k v; do S["$k"]="$v"; done < <(resource_sizing_compute "$@")
}

echo "Basic plan (0.28G / 7% CPU) never forks below 2 workers and keeps opcache at the floor"
size 280 70
assert_eq 128 "${S[CC_SIZING_PHP_MEMORY_LIMIT_MB]}" "memory_limit"
assert_eq 64  "${S[CC_SIZING_OPCACHE_MB]}" "opcache"
assert_eq 8   "${S[CC_SIZING_OPCACHE_INTERNED_MB]}" "interned strings"
assert_eq 2   "${S[CC_SIZING_FPM_MAX_CHILDREN]}" "max_children floor"
assert_eq 1   "${S[CC_SIZING_NGINX_WORKERS]}" "nginx workers"

echo "Premium plan (1G / 25% CPU) is CPU-bound to 3 workers"
size 953 250
assert_eq 128 "${S[CC_SIZING_PHP_MEMORY_LIMIT_MB]}" "memory_limit"
assert_eq 112 "${S[CC_SIZING_OPCACHE_MB]}" "opcache rounded to 16"
assert_eq 10  "${S[CC_SIZING_FPM_MEM_BASED]}" "memory-bound children"
assert_eq 3   "${S[CC_SIZING_FPM_CPU_BASED]}" "cpu-bound children"
assert_eq 3   "${S[CC_SIZING_FPM_MAX_CHILDREN]}" "max_children = min(mem, cpu)"
assert_eq 1   "${S[CC_SIZING_FPM_MIN_SPARE]}" "min_spare"
assert_eq 2   "${S[CC_SIZING_FPM_MAX_SPARE]}" "max_spare"
assert_eq 1   "${S[CC_SIZING_FPM_START_SERVERS]}" "start_servers"

echo "2G / 1 CPU gets 256M requests and 12 workers"
size 2000 1000
assert_eq 256 "${S[CC_SIZING_PHP_MEMORY_LIMIT_MB]}" "memory_limit"
assert_eq 256 "${S[CC_SIZING_OPCACHE_MB]}" "opcache cap"
assert_eq 32  "${S[CC_SIZING_OPCACHE_INTERNED_MB]}" "interned strings"
assert_eq 12  "${S[CC_SIZING_FPM_MAX_CHILDREN]}" "max_children"
assert_eq 1   "${S[CC_SIZING_NGINX_WORKERS]}" "nginx workers"

echo "4G / 2 CPU"
size 4000 2000
assert_eq 24 "${S[CC_SIZING_FPM_MAX_CHILDREN]}" "max_children"
assert_eq 2  "${S[CC_SIZING_NGINX_WORKERS]}" "nginx workers"

echo "very large containers hit the ceilings"
size 16000 8000
assert_eq 64 "${S[CC_SIZING_FPM_MAX_CHILDREN]}" "max_children ceiling"
assert_eq 4  "${S[CC_SIZING_NGINX_WORKERS]}" "nginx workers ceiling"

echo "invariants hold across a sweep of sizes"
for mem in 256 280 512 600 953 1000 1500 1536 2000 3000 4000 6000 8000 12000 16000 32000; do
    for cpu in 50 70 100 150 250 500 1000 2000 4000 8000; do
        size "$mem" "$cpu"
        mc="${S[CC_SIZING_FPM_MAX_CHILDREN]}"
        assert_le "${S[CC_SIZING_FPM_MIN_SPARE]}" "${S[CC_SIZING_FPM_START_SERVERS]}" "min_spare <= start ($mem/$cpu)"
        assert_le "${S[CC_SIZING_FPM_START_SERVERS]}" "${S[CC_SIZING_FPM_MAX_SPARE]}" "start <= max_spare ($mem/$cpu)"
        assert_le "${S[CC_SIZING_FPM_MAX_SPARE]}" "$mc" "max_spare <= max_children ($mem/$cpu)"
        assert_le 2 "$mc" "max_children >= 2 ($mem/$cpu)"
        assert_le "$mc" 64 "max_children <= 64 ($mem/$cpu)"
        assert_le 64 "${S[CC_SIZING_OPCACHE_MB]}" "opcache >= 64 ($mem/$cpu)"
        assert_le "${S[CC_SIZING_OPCACHE_MB]}" 256 "opcache <= 256 ($mem/$cpu)"
        assert_eq 0 $(( S[CC_SIZING_OPCACHE_MB] % 16 )) "opcache multiple of 16 ($mem/$cpu)"
        # The budget fits the container whenever the floor of 2 workers was not forced.
        if [ "$mc" -gt 2 ]; then
            budget=$(( S[CC_SIZING_RESERVED_MB] + S[CC_SIZING_OPCACHE_MB] + mc * S[CC_SIZING_WORKER_MB] ))
            assert_le "$budget" "$mem" "memory budget fits ($mem/$cpu)"
        fi
    done
done

echo "tuning knobs"
PHP_WORKER_MEMORY_MB=200 size 2000 4000
assert_eq 200 "${S[CC_SIZING_WORKER_MB]}" "worker budget knob"
assert_eq 7   "${S[CC_SIZING_FPM_MAX_CHILDREN]}" "fewer children with a bigger worker budget"
PHP_FPM_WORKERS_PER_CPU=4 size 4000 1000
assert_eq 4 "${S[CC_SIZING_FPM_MAX_CHILDREN]}" "workers-per-cpu knob"
out="$(PHP_FPM_WORKERS_PER_CPU=lots resource_sizing_compute 2000 1000 2>&1)"
assert_contains "$out" "Invalid PHP_FPM_WORKERS_PER_CPU" "invalid knob is reported"
assert_contains "$out" "CC_SIZING_FPM_MAX_CHILDREN=12" "invalid knob falls back to the default"

echo "ini size parsing"
assert_eq 256  "$(resource_sizing_ini_size_to_mb 256M)" "256M"
assert_eq 1024 "$(resource_sizing_ini_size_to_mb 1G)" "1G"
assert_eq 128  "$(resource_sizing_ini_size_to_mb 134217728)" "bytes"
assert_eq 0    "$(resource_sizing_ini_size_to_mb 512K)" "sub-MiB rounds to 0"
assert_eq ""   "$(resource_sizing_ini_size_to_mb -1)" "-1 is unparseable"
assert_eq ""   "$(resource_sizing_ini_size_to_mb 'lots')" "garbage is unparseable"

echo "override lookup follows the merge rules (last wins, comments ignored, whitespace tolerated)"
blob=$'; memory_limit = 1G\nmemory_limit = 128M\nfoo=1\n  memory_limit=512M  '
assert_eq 512M "$(resource_sizing_override_value memory_limit "$blob")" "last occurrence"
assert_eq ""   "$(resource_sizing_override_value max_input_vars "$blob")" "absent key"
assert_eq 9    "$(resource_sizing_override_value pm.max_children $'[www]\npm.max_children = 9')" "fpm key"

echo "a pinned memory_limit shrinks the pool"
size 953 250 512
assert_eq 512 "${S[CC_SIZING_PHP_MEMORY_LIMIT_MB]}" "pinned limit"
assert_eq 256 "${S[CC_SIZING_WORKER_MB]}" "budget follows it"
assert_eq 2   "${S[CC_SIZING_FPM_MAX_CHILDREN]}" "fewer workers"

echo "spare pool invariants for pinned child counts"
for n in 1 2 3 5 9 17 64; do
    read -r start min max < <(resource_sizing_spares "$n")
    assert_le "$min" "$start" "min <= start ($n)"
    assert_le "$start" "$max" "start <= max ($n)"
    assert_le "$max" "$n" "max <= children ($n)"
    assert_le 1 "$min" "min >= 1 ($n)"
done

echo "resource_sizing_load reads the cgroup once and exports"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
export CONTAINER_RESOURCES_CGROUP_ROOT="$tmp/cg" CONTAINER_RESOURCES_PROC_ROOT="$tmp/proc"
make_cgroup_fixture "$tmp/cg" v2 999997440 25000
unset CC_SIZING_LOADED
resource_sizing_load
assert_eq cgroup "$CC_SIZING_SOURCE" "source"
assert_eq 3 "$CC_SIZING_FPM_MAX_CHILDREN" "exported max_children"
assert_eq 3 "$(bash -c 'echo "$CC_SIZING_FPM_MAX_CHILDREN"')" "visible to child processes"
make_cgroup_fixture "$tmp/cg" v2 max max
resource_sizing_load
assert_eq 3 "$CC_SIZING_FPM_MAX_CHILDREN" "second load is a no-op"

echo "resource_sizing_load feeds customer overrides back into the sizing"
make_cgroup_fixture "$tmp/cg" v2 999997440 25000
unset CC_SIZING_LOADED
out="$(WORDPRESS_CUSTOM_INI=$'max_input_vars = 5000\nmemory_limit = 512M' resource_sizing_load; echo "children=$CC_SIZING_FPM_MAX_CHILDREN limit=$CC_SIZING_PHP_MEMORY_LIMIT_MB")"
assert_contains "$out" "memory_limit pinned to 512M" "pinned limit is logged"
assert_contains "$out" "children=2 limit=512" "pool shrinks with the pinned limit"
unset CC_SIZING_LOADED
out="$(WORDPRESS_CUSTOM_INI='memory_limit = -1' resource_sizing_load; echo "children=$CC_SIZING_FPM_MAX_CHILDREN limit=$CC_SIZING_PHP_MEMORY_LIMIT_MB")"
assert_contains "$out" "unlimited or unparseable" "unlimited limit is reported"
assert_contains "$out" "children=3 limit=128" "and ignored for sizing"
unset CC_SIZING_LOADED
out="$(WORDPRESS_FPM_CONF=$'[www]\npm.max_children = 9' resource_sizing_load; echo "pool=$CC_SIZING_FPM_MAX_CHILDREN/$CC_SIZING_FPM_START_SERVERS/$CC_SIZING_FPM_MIN_SPARE/$CC_SIZING_FPM_MAX_SPARE")"
assert_contains "$out" "pm.max_children pinned to 9" "pinned children is logged"
assert_contains "$out" "pool=9/3/2/5" "spares re-derived from the pinned count"
unset CC_SIZING_LOADED
out="$(WORDPRESS_FPM_CONF=$'[www]\npm.max_children = many' resource_sizing_load; echo "pool=$CC_SIZING_FPM_MAX_CHILDREN")"
assert_contains "$out" "not a positive integer" "bad pinned count is reported"
assert_contains "$out" "pool=3" "and ignored"

echo "resource_sizing_load falls back to the host when there are no limits"
make_cgroup_fixture "$tmp/cg" v2 max max
unset CC_SIZING_LOADED
mkdir -p "$tmp/proc"; printf 'MemTotal:       2097152 kB\n' > "$tmp/proc/meminfo"
out="$(CONTAINER_RESOURCES_NPROC=2 resource_sizing_load; echo "$CC_SIZING_SOURCE $CC_SIZING_MEM_MB $CC_SIZING_CPU_MC")"
assert_contains "$out" "No cgroup memory limit found" "memory fallback is logged"
assert_contains "$out" "No cgroup CPU quota found" "cpu fallback is logged"
assert_contains "$out" "host 2048 2000" "host figures used"

finish
