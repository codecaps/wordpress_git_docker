#!/bin/bash
# Runs the real configure scripts against a fake cgroup and checks the files
# they write: sized defaults, and that customer overrides still win.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/lib.sh"
SCRIPTS="$HERE/../scripts"

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/php/conf.d" "$tmp/nginx"
export CONTAINER_RESOURCES_CGROUP_ROOT="$tmp/cg"
export PHP_INI_DIR="$tmp/php"
export WORDPRESS_FPM_CONF_PATH="$tmp/fpm.conf"
export NGINX_GENERATED_DIR="$tmp/nginx"
unset CC_SIZING_LOADED WORDPRESS_CUSTOM_INI WORDPRESS_FPM_CONF
make_cgroup_fixture "$tmp/cg" v2 999997440 25000   # the 1G / 25% capsule

echo "php.ini defaults are sized to the capsule"
"$BASH" "$SCRIPTS/configure_wordpress_custom_ini.sh" >/dev/null
ini="$(cat "$tmp/php/conf.d/zz-custom.ini")"
assert_contains "$ini" $'\nmemory_limit = 128M\n' "memory_limit"
assert_contains "$ini" $'\nopcache.memory_consumption = 112\n' "opcache size"
assert_contains "$ini" $'\nopcache.interned_strings_buffer = 8\n' "interned strings"
assert_contains "$ini" $'\nupload_max_filesize = 64M\n' "upload default untouched"

echo "WORDPRESS_CUSTOM_INI overrides the sized defaults and adds new keys"
WORDPRESS_CUSTOM_INI=$'memory_limit = 512M\nopcache.memory_consumption=200\nmax_input_vars = 9000\nmy.new_key = 1' \
    "$BASH" "$SCRIPTS/configure_wordpress_custom_ini.sh" >/dev/null
ini="$(cat "$tmp/php/conf.d/zz-custom.ini")"
assert_contains "$ini" $'\nmemory_limit = 512M\n' "override memory_limit"
assert_not_contains "$ini" "memory_limit = 128M" "default memory_limit replaced"
assert_contains "$ini" $'\nopcache.memory_consumption=200\n' "override opcache"
assert_contains "$ini" $'\nmax_input_vars = 9000\n' "override max_input_vars"
assert_contains "$ini" $'\nmy.new_key = 1' "unknown keys appended"
assert_eq 1 "$(grep -c '^memory_limit' "$tmp/php/conf.d/zz-custom.ini")" "memory_limit appears once"

echo "FPM pool defaults are sized to the capsule"
"$BASH" "$SCRIPTS/configure_wordpress_fpm_conf.sh" >/dev/null
fpm="$(cat "$tmp/fpm.conf")"
assert_contains "$fpm" $'\npm.max_children = 3\n' "max_children"
assert_contains "$fpm" $'\npm.start_servers = 1\n' "start_servers"
assert_contains "$fpm" $'\npm.min_spare_servers = 1\n' "min_spare"
assert_contains "$fpm" $'\npm.max_spare_servers = 2\n' "max_spare"
assert_contains "$fpm" $'\nrequest_slowlog_timeout = 0\n' "slowlog off"

echo "WORDPRESS_FPM_CONF overrides the sized pool"
WORDPRESS_FPM_CONF=$'[www]\npm = static\npm.max_children = 10' "$BASH" "$SCRIPTS/configure_wordpress_fpm_conf.sh" >/dev/null
fpm="$(cat "$tmp/fpm.conf")"
assert_contains "$fpm" $'\npm = static\n' "override pm"
assert_contains "$fpm" $'\npm.max_children = 10\n' "override max_children"
assert_not_contains "$fpm" "pm.max_children = 3" "default max_children replaced"

echo "pinning only pm.max_children keeps the pool startable (spares re-derived)"
unset CC_SIZING_LOADED
WORDPRESS_FPM_CONF=$'[www]\npm.max_children = 1' "$BASH" "$SCRIPTS/configure_wordpress_fpm_conf.sh" >/dev/null
fpm="$(cat "$tmp/fpm.conf")"
assert_contains "$fpm" $'\npm.max_children = 1\n' "pinned max_children"
assert_contains "$fpm" $'\npm.max_spare_servers = 1\n' "max_spare <= pinned max_children"
assert_contains "$fpm" $'\npm.min_spare_servers = 1\n' "min_spare"
assert_contains "$fpm" $'\npm.start_servers = 1\n' "start"

echo "a pinned memory_limit shrinks the pool written by the FPM script"
unset CC_SIZING_LOADED
WORDPRESS_CUSTOM_INI='memory_limit = 512M' "$BASH" "$SCRIPTS/configure_wordpress_fpm_conf.sh" >/dev/null
assert_contains "$(cat "$tmp/fpm.conf")" $'\npm.max_children = 2\n' "2 workers at 512M on 1G"
unset CC_SIZING_LOADED

echo "nginx worker count follows the CPU quota"
"$BASH" "$SCRIPTS/configure_nginx_overrides.sh" >/dev/null
assert_contains "$(cat "$tmp/nginx/generated_main.conf")" "worker_processes 1;" "1 worker for 0.25 CPU"
assert_contains "$(cat "$tmp/nginx/generated_php_inflight.conf")" "limit_conn php_inflight 12;" "in-flight cap for 3 workers"
assert_contains "$(cat "$tmp/nginx/generated_php_inflight.conf")" "limit_conn per_ip_conn 30;" "per-IP limit restated beside the cap"
# Every location that routes to PHP must carry the include, since limit_conn is
# evaluated only in the first location a request lands in.
nconf="$HERE/../default.conf"
assert_eq 7 "$(grep -c 'include /etc/nginx/conf.d/generated_php_inflight.conf;' "$nconf")" "include present in all 7 PHP-bound locations"
assert_contains "$(sed -n '/location \/ {/,/}/p' "$nconf")" "generated_php_inflight.conf" "include in location /"
unset CC_SIZING_LOADED
make_cgroup_fixture "$tmp/cg" v2 4294967296 300000
"$BASH" "$SCRIPTS/configure_nginx_overrides.sh" >/dev/null
assert_contains "$(cat "$tmp/nginx/generated_main.conf")" "worker_processes 3;" "3 workers for 3 CPUs"

echo "a bigger capsule gets bigger defaults from the same scripts"
unset CC_SIZING_LOADED
make_cgroup_fixture "$tmp/cg" v1 4294967296 200000
"$BASH" "$SCRIPTS/configure_wordpress_custom_ini.sh" >/dev/null
"$BASH" "$SCRIPTS/configure_wordpress_fpm_conf.sh" >/dev/null
assert_contains "$(cat "$tmp/php/conf.d/zz-custom.ini")" $'\nmemory_limit = 256M\n' "4G memory_limit"
assert_contains "$(cat "$tmp/fpm.conf")" $'\npm.max_children = 24\n' "4G/2CPU max_children"

finish
