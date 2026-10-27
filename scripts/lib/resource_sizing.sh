#!/bin/bash
#
# Sizes PHP, PHP-FPM and nginx to the capsule's actual CPU and memory limits.
#
# Why this exists: the image used to ship one fixed set of numbers
# (pm.max_children=24, memory_limit=256M, opcache 256M) regardless of capsule
# size. That is a worst case of 24 x 256M = 6G of PHP heap on a capsule that
# may have 1G - a production capsule was OOM-killed under a modest traffic
# burst exactly this way. The defaults below are derived from the cgroup
# limits at container start, so the same image is safe on a 0.28G Basic
# capsule and makes full use of a multi-GB one.
#
# Everything computed here is only a DEFAULT. WORDPRESS_CUSTOM_INI and
# WORDPRESS_FPM_CONF are merged afterwards and win, so any value can still be
# pinned by hand. Two overrides are also fed back into the sizing so the
# features compose instead of fighting:
#   - a memory_limit in WORDPRESS_CUSTOM_INI becomes the per-request cap the
#     worker budget is derived from (a bigger limit means fewer workers);
#   - a pm.max_children in WORDPRESS_FPM_CONF re-derives the spare pool, since
#     PHP-FPM refuses to start when max_spare_servers exceeds max_children.
#
# Model (all sizes in MiB, integer arithmetic):
#
#   reserved   = 80 + mem/16         nginx, exporters, FPM master, page cache
#   opcache    = clamp(mem/8, 64, 256) rounded to 16   shared, counted once
#   mem_limit  = 128 below 1.5G, else 256               per-request PHP cap
#   worker     = PHP_WORKER_MEMORY_MB, default mem_limit/2
#                private RSS budgeted per FPM worker. WordPress front-end
#                requests peak well under the limit; measured ~40-70M on a
#                heavy multilingual site. Requests above it are still allowed
#                (up to mem_limit) - this is the budget, not a cap.
#   children   = min( (mem - reserved - opcache) / worker,
#                     ceil(cpu * PHP_FPM_WORKERS_PER_CPU) )   clamped 2..64
#   nginx      = clamp(ceil(cpu), 1, 4) worker processes
#   inflight   = clamp(children * PHP_INFLIGHT_PER_WORKER, 16, 1024)
#                concurrent PHP requests nginx accepts before answering 429.
#                Everything past the FPM pool waits in a queue; without a cap
#                a burst queues thousands of requests that each hold the
#                pool for a minute, and the capsule stays unresponsive for
#                hours after the burst has ended.
#
# The CPU bound matters as much as the memory bound: PHP is CPU-bound once
# OPcache is warm, so workers beyond a few per core only add memory and
# context switching, not throughput. Excess requests wait in a short, bounded
# queue in front of the pool (the in-flight cap above) instead.

SIZING_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./container_resources.sh
source "$SIZING_LIB_DIR/container_resources.sh"

readonly SIZING_DEFAULT_WORKERS_PER_CPU=12
readonly SIZING_DEFAULT_INFLIGHT_PER_WORKER=8
readonly SIZING_MIN_INFLIGHT=16
readonly SIZING_MAX_INFLIGHT=1024
readonly SIZING_MIN_CHILDREN=2
readonly SIZING_MAX_CHILDREN=64
readonly SIZING_MAX_NGINX_WORKERS=4
readonly SIZING_FALLBACK_MEM_MB=1024
readonly SIZING_FALLBACK_CPU_MC=1000

_sizing_log() {
    echo "[sizing] $*"
}

_sizing_clamp() {
    local value="$1" min="$2" max="$3"
    if [ "$value" -lt "$min" ]; then value="$min"; fi
    if [ "$value" -gt "$max" ]; then value="$max"; fi
    echo "$value"
}

_sizing_positive_int_or_default() {
    local value="$1" default="$2" name="$3"
    if [ -z "$value" ]; then
        echo "$default"
        return
    fi
    if [[ "$value" =~ ^[0-9]+$ ]] && [ "$value" -ge 1 ]; then
        echo "$value"
        return
    fi
    _sizing_log "Invalid ${name} value '${value}'. Falling back to ${default}." >&2
    echo "$default"
}

# Converts a php.ini shorthand size ("256M", "1G", "512K", "134217728") to
# whole MiB. Prints nothing for anything it cannot parse, or for -1/0 (no limit).
resource_sizing_ini_size_to_mb() {
    local value="${1//[[:space:]]/}" number unit
    [[ "$value" =~ ^([0-9]+)([KkMmGg]?)$ ]] || return 0
    number="${BASH_REMATCH[1]}"; unit="${BASH_REMATCH[2]}"
    case "${unit^^}" in
        G) echo $(( number * 1024 )) ;;
        M) echo "$number" ;;
        K) echo $(( number / 1024 )) ;;
        *) echo $(( number / 1024 / 1024 )) ;;
    esac
}

# Prints the value a customer pinned for KEY in an ini-style override blob
# (last occurrence wins, as in the merge), or nothing. Used to feed the two
# overrides that affect the sizing back into it.
resource_sizing_override_value() {
    local key="$1" blob="$2"
    printf '%s\n' "$blob" | awk -v key="$key" '
        /^[[:space:]]*[#;]/ { next }
        {
            pos = index($0, "=")
            if (!pos) next
            lhs = substr($0, 1, pos - 1); gsub(/[[:space:]]/, "", lhs)
            if (lhs != key) next
            rhs = substr($0, pos + 1); gsub(/^[[:space:]]+|[[:space:]]+$/, "", rhs)
            value = rhs
        }
        END { if (value != "") print value }'
}

# Prints the in-flight PHP request cap for a pool of MAX_CHILDREN workers.
resource_sizing_inflight() {
    local max_children="$1" per_worker
    per_worker="$(_sizing_positive_int_or_default "${PHP_INFLIGHT_PER_WORKER:-}" "$SIZING_DEFAULT_INFLIGHT_PER_WORKER" PHP_INFLIGHT_PER_WORKER)"
    _sizing_clamp $(( max_children * per_worker )) "$SIZING_MIN_INFLIGHT" "$SIZING_MAX_INFLIGHT"
}

# Prints "start min_spare max_spare" for a pool of MAX_CHILDREN workers,
# honouring PHP-FPM's rule min_spare <= start <= max_spare <= max_children.
resource_sizing_spares() {
    local max_children="$1" min_spare max_spare start_servers
    min_spare=$(( max_children / 4 )); if [ "$min_spare" -lt 1 ]; then min_spare=1; fi
    max_spare=$(( (max_children + 1) / 2 )); if [ "$max_spare" -lt "$min_spare" ]; then max_spare="$min_spare"; fi
    start_servers=$(_sizing_clamp $(( (max_children + 2) / 3 )) "$min_spare" "$max_spare")
    echo "$start_servers $min_spare $max_spare"
}

# Pure function: prints the sizing for a container with MEM_MB of memory and
# CPU_MC millicores of CPU, one KEY=VALUE per line, keys prefixed CC_SIZING_.
# An optional third argument pins the per-request memory_limit (MiB) instead of
# the tiered default. Reads three optional tuning knobs from the environment:
#   PHP_WORKER_MEMORY_MB     private memory budgeted per FPM worker
#   PHP_FPM_WORKERS_PER_CPU  FPM worker oversubscription per core (default 12)
#   PHP_INFLIGHT_PER_WORKER  queued+active PHP requests allowed per worker (default 8)
resource_sizing_compute() {
    local mem_mb="$1" cpu_mc="$2" memory_limit_override_mb="${3:-}"
    local workers_per_cpu worker_mb memory_limit_mb opcache_mb interned_mb reserved_mb
    local available_mb mem_based cpu_based max_children min_spare max_spare start_servers nginx_workers max_inflight

    workers_per_cpu="$(_sizing_positive_int_or_default "${PHP_FPM_WORKERS_PER_CPU:-}" "$SIZING_DEFAULT_WORKERS_PER_CPU" PHP_FPM_WORKERS_PER_CPU)"

    if [ -n "$memory_limit_override_mb" ]; then memory_limit_mb="$memory_limit_override_mb"
    elif [ "$mem_mb" -ge 1536 ]; then memory_limit_mb=256
    else memory_limit_mb=128; fi

    opcache_mb=$(_sizing_clamp $(( mem_mb / 8 )) 64 256)
    opcache_mb=$(( (opcache_mb + 8) / 16 * 16 ))
    if [ "$opcache_mb" -ge 192 ]; then interned_mb=32
    elif [ "$opcache_mb" -ge 128 ]; then interned_mb=16
    else interned_mb=8; fi

    reserved_mb=$(( 80 + mem_mb / 16 ))
    worker_mb="$(_sizing_positive_int_or_default "${PHP_WORKER_MEMORY_MB:-}" $(( memory_limit_mb / 2 )) PHP_WORKER_MEMORY_MB)"

    available_mb=$(( mem_mb - reserved_mb - opcache_mb ))
    if [ "$available_mb" -lt 0 ]; then available_mb=0; fi
    mem_based=$(( available_mb / worker_mb ))
    cpu_based=$(( (cpu_mc * workers_per_cpu + 999) / 1000 ))

    max_children="$mem_based"
    if [ "$cpu_based" -lt "$max_children" ]; then max_children="$cpu_based"; fi
    max_children=$(_sizing_clamp "$max_children" "$SIZING_MIN_CHILDREN" "$SIZING_MAX_CHILDREN")

    read -r start_servers min_spare max_spare < <(resource_sizing_spares "$max_children")

    nginx_workers=$(_sizing_clamp $(( (cpu_mc + 999) / 1000 )) 1 "$SIZING_MAX_NGINX_WORKERS")
    max_inflight="$(resource_sizing_inflight "$max_children")"

    cat <<OUT
CC_SIZING_MEM_MB=${mem_mb}
CC_SIZING_CPU_MC=${cpu_mc}
CC_SIZING_RESERVED_MB=${reserved_mb}
CC_SIZING_PHP_MEMORY_LIMIT_MB=${memory_limit_mb}
CC_SIZING_OPCACHE_MB=${opcache_mb}
CC_SIZING_OPCACHE_INTERNED_MB=${interned_mb}
CC_SIZING_WORKER_MB=${worker_mb}
CC_SIZING_FPM_MEM_BASED=${mem_based}
CC_SIZING_FPM_CPU_BASED=${cpu_based}
CC_SIZING_FPM_MAX_CHILDREN=${max_children}
CC_SIZING_FPM_START_SERVERS=${start_servers}
CC_SIZING_FPM_MIN_SPARE=${min_spare}
CC_SIZING_FPM_MAX_SPARE=${max_spare}
CC_SIZING_NGINX_WORKERS=${nginx_workers}
CC_SIZING_PHP_MAX_INFLIGHT=${max_inflight}
OUT
}

# Detects the container limits, computes the sizing once and exports every
# CC_SIZING_* variable. Idempotent: child scripts inherit the exported values
# and calling this again is a no-op, so run.sh and each configure script can
# all call it safely.
resource_sizing_load() {
    if [ "${CC_SIZING_LOADED:-}" = "1" ]; then
        return
    fi

    local mem_mb cpu_mc source="cgroup" line
    local ini_limit ini_limit_mb="" pinned_children=""
    mem_mb="$(container_resources_memory_limit_mb)"
    cpu_mc="$(container_resources_cpu_millicores)"

    if [ "$mem_mb" -le 0 ]; then
        mem_mb="$(container_resources_host_memory_mb)"
        [ "$mem_mb" -gt 0 ] || mem_mb="$SIZING_FALLBACK_MEM_MB"
        source="host"
        _sizing_log "No cgroup memory limit found; sizing from host memory (${mem_mb}M)."
    fi
    if [ "$cpu_mc" -le 0 ]; then
        cpu_mc=$(( $(container_resources_host_cpus) * 1000 ))
        [ "$cpu_mc" -gt 0 ] || cpu_mc="$SIZING_FALLBACK_CPU_MC"
        source="host"
        _sizing_log "No cgroup CPU quota found; sizing from host CPUs (${cpu_mc}m)."
    fi

    # A customer-pinned memory_limit changes the worst case of every worker, so
    # the pool is sized from it rather than from the tiered default.
    ini_limit="$(resource_sizing_override_value memory_limit "${WORDPRESS_CUSTOM_INI:-}")"
    if [ -n "$ini_limit" ]; then
        ini_limit_mb="$(resource_sizing_ini_size_to_mb "$ini_limit")"
        if [ -n "$ini_limit_mb" ] && [ "$ini_limit_mb" -ge 1 ]; then
            _sizing_log "memory_limit pinned to ${ini_limit} by WORDPRESS_CUSTOM_INI; sizing the worker pool from it."
        else
            _sizing_log "memory_limit '${ini_limit}' in WORDPRESS_CUSTOM_INI is unlimited or unparseable; sizing the worker pool from the default limit."
            ini_limit_mb=""
        fi
    fi

    while IFS= read -r line; do
        export "${line?}"
    done < <(resource_sizing_compute "$mem_mb" "$cpu_mc" "$ini_limit_mb")

    # A customer-pinned pm.max_children must carry its spare pool with it, or
    # PHP-FPM rejects the config (max_spare_servers > max_children).
    pinned_children="$(resource_sizing_override_value pm.max_children "${WORDPRESS_FPM_CONF:-}")"
    if [ -n "$pinned_children" ]; then
        if [[ "$pinned_children" =~ ^[0-9]+$ ]] && [ "$pinned_children" -ge 1 ]; then
            read -r CC_SIZING_FPM_START_SERVERS CC_SIZING_FPM_MIN_SPARE CC_SIZING_FPM_MAX_SPARE \
                < <(resource_sizing_spares "$pinned_children")
            export CC_SIZING_FPM_MAX_CHILDREN="$pinned_children"
            export CC_SIZING_FPM_START_SERVERS CC_SIZING_FPM_MIN_SPARE CC_SIZING_FPM_MAX_SPARE
            CC_SIZING_PHP_MAX_INFLIGHT="$(resource_sizing_inflight "$pinned_children")"
            export CC_SIZING_PHP_MAX_INFLIGHT
            _sizing_log "pm.max_children pinned to ${pinned_children} by WORDPRESS_FPM_CONF; spare pool re-derived from it."
        else
            _sizing_log "pm.max_children '${pinned_children}' in WORDPRESS_FPM_CONF is not a positive integer; leaving the sized pool."
        fi
    fi

    export CC_SIZING_SOURCE="$source"
    export CC_SIZING_LOADED=1
}

# One-line boot summary, in the same spirit as the "[nginx-overrides]" block.
resource_sizing_log() {
    _sizing_log "Container limits (${CC_SIZING_SOURCE}): memory=${CC_SIZING_MEM_MB}M cpu=${CC_SIZING_CPU_MC}m"
    _sizing_log "  php: memory_limit=${CC_SIZING_PHP_MEMORY_LIMIT_MB}M opcache=${CC_SIZING_OPCACHE_MB}M interned_strings=${CC_SIZING_OPCACHE_INTERNED_MB}M"
    _sizing_log "  php-fpm: max_children=${CC_SIZING_FPM_MAX_CHILDREN} (memory-bound=${CC_SIZING_FPM_MEM_BASED}, cpu-bound=${CC_SIZING_FPM_CPU_BASED}, worker_budget=${CC_SIZING_WORKER_MB}M, reserved=${CC_SIZING_RESERVED_MB}M) start=${CC_SIZING_FPM_START_SERVERS} spare=${CC_SIZING_FPM_MIN_SPARE}-${CC_SIZING_FPM_MAX_SPARE}"
    _sizing_log "  nginx: worker_processes=${CC_SIZING_NGINX_WORKERS} max_inflight_php_requests=${CC_SIZING_PHP_MAX_INFLIGHT}"
}
