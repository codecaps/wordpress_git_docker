#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib/merge_and_write_config.sh
source "$SCRIPT_DIR/lib/merge_and_write_config.sh"

log() { echo "[fpm-sizing] $*" >&2; }

# ---------------------------------------------------------------------------
# Resource-aware PHP-FPM sizing.
#
# pm.max_children (and the dynamic spare pool) are computed at startup from the
# container's actual cgroup CPU/memory limits, so the same image runs safely on
# a 512Mi capsule and fully utilises a multi-GiB one. The result is the tighter
# of a memory-bound and a CPU-bound estimate.
#
# Everything here is only the DEFAULT — WORDPRESS_FPM_CONF is merged afterwards
# and wins, so any value can still be pinned by hand.
#
# Tunables (env, with fallbacks):
#   FPM_WORKER_MEM_MB     estimated RSS per PHP worker                 (default 90)
#   FPM_RESERVED_MEM_MB   memory held back for opcache/nginx/exporters/OS (default 480)
#   FPM_WORKERS_PER_CORE  worker oversubscription per core; PHP spends
#                         most time waiting on MySQL so this is high   (default 16)
#   FPM_MIN_CHILDREN      floor so tiny containers still serve         (default 3)
#   FPM_MAX_CHILDREN      optional hard ceiling (0 = none)             (default 0)
# ---------------------------------------------------------------------------

WORKER_MEM_MB="${FPM_WORKER_MEM_MB:-90}"
RESERVED_MEM_MB="${FPM_RESERVED_MEM_MB:-480}"
WORKERS_PER_CORE="${FPM_WORKERS_PER_CORE:-16}"
MIN_CHILDREN="${FPM_MIN_CHILDREN:-3}"
MAX_CHILDREN_CEIL="${FPM_MAX_CHILDREN:-0}"

# --- Detect the memory limit in MiB (0 = none/unlimited detected) ---
detect_mem_limit_mb() {
    local bytes=""
    if [ -r /sys/fs/cgroup/memory.max ]; then                       # cgroup v2
        bytes="$(cat /sys/fs/cgroup/memory.max 2>/dev/null || true)"
    elif [ -r /sys/fs/cgroup/memory/memory.limit_in_bytes ]; then   # cgroup v1
        bytes="$(cat /sys/fs/cgroup/memory/memory.limit_in_bytes 2>/dev/null || true)"
    fi
    if [ -z "$bytes" ] || [ "$bytes" = "max" ] || ! [[ "$bytes" =~ ^[0-9]+$ ]]; then
        echo 0; return
    fi
    # cgroup v1 "unlimited" is a near-2^63 sentinel; anything over 1TiB is not a real cap.
    if [ "$bytes" -gt $((1024 * 1024 * 1024 * 1024)) ]; then
        echo 0; return
    fi
    echo $(( bytes / 1024 / 1024 ))
}

# --- Detect the CPU quota in millicores (0 = no quota) ---
detect_cpu_millicores() {
    local quota="" period=""
    if [ -r /sys/fs/cgroup/cpu.max ]; then                          # cgroup v2: "<quota> <period>"
        read -r quota period < /sys/fs/cgroup/cpu.max 2>/dev/null || true
    elif [ -r /sys/fs/cgroup/cpu/cpu.cfs_quota_us ] && [ -r /sys/fs/cgroup/cpu/cpu.cfs_period_us ]; then
        quota="$(cat /sys/fs/cgroup/cpu/cpu.cfs_quota_us 2>/dev/null || true)"
        period="$(cat /sys/fs/cgroup/cpu/cpu.cfs_period_us 2>/dev/null || true)"
    fi
    if [ -z "$quota" ] || [ "$quota" = "max" ] || [ "$quota" = "-1" ]; then
        echo 0; return
    fi
    if ! [[ "$quota" =~ ^[0-9]+$ ]] || ! [[ "${period:-}" =~ ^[0-9]+$ ]] || [ "${period:-0}" -eq 0 ]; then
        echo 0; return
    fi
    echo $(( quota * 1000 / period ))
}

mem_mb="$(detect_mem_limit_mb)"
cpu_mc="$(detect_cpu_millicores)"

# Fall back to host figures when a limit isn't exposed.
if [ "$mem_mb" -le 0 ]; then
    mem_mb="$(awk '/MemTotal/ {printf "%d", $2 / 1024}' /proc/meminfo 2>/dev/null || echo 1024)"
    log "No cgroup memory limit detected; falling back to MemTotal=${mem_mb}MiB"
fi
if [ "$cpu_mc" -le 0 ]; then
    cpu_mc=$(( $(nproc 2>/dev/null || echo 1) * 1000 ))
    log "No cgroup CPU quota detected; falling back to nproc=${cpu_mc}m"
fi

# Memory-bound estimate.
mem_for_php=$(( mem_mb - RESERVED_MEM_MB ))
if [ "$mem_for_php" -lt 0 ]; then mem_for_php=0; fi
mem_based=$(( mem_for_php / WORKER_MEM_MB ))

# CPU-bound estimate.
cpu_based=$(( cpu_mc * WORKERS_PER_CORE / 1000 ))

# Take the tighter of the two, then clamp to [MIN_CHILDREN, optional ceiling].
max_children=$mem_based
if [ "$cpu_based" -lt "$max_children" ]; then max_children=$cpu_based; fi
if [ "$max_children" -lt "$MIN_CHILDREN" ]; then max_children=$MIN_CHILDREN; fi
if [ "$MAX_CHILDREN_CEIL" -gt 0 ] && [ "$max_children" -gt "$MAX_CHILDREN_CEIL" ]; then
    max_children=$MAX_CHILDREN_CEIL
fi

# Derive the dynamic spare pool from max_children, keeping PHP-FPM's invariant:
# min_spare <= start_servers <= max_spare <= max_children.
min_spare=$(( max_children / 4 ))
if [ "$min_spare" -lt 2 ]; then min_spare=2; fi
max_spare=$(( max_children * 3 / 4 ))
if [ "$max_spare" -le "$min_spare" ]; then max_spare=$(( min_spare + 1 )); fi
if [ "$max_spare" -gt "$max_children" ]; then max_spare=$max_children; fi
start_servers=$(( (min_spare + max_spare) / 2 ))
if [ "$start_servers" -lt "$min_spare" ]; then start_servers=$min_spare; fi

log "mem=${mem_mb}MiB cpu=${cpu_mc}m reserved=${RESERVED_MEM_MB}MiB worker=${WORKER_MEM_MB}MiB -> max_children=${max_children} (mem_based=${mem_based}, cpu_based=${cpu_based}) start=${start_servers} spare=${min_spare}-${max_spare}"

DEFAULT_WORDPRESS_FPM_CONF="[global]
; Keep PHP-FPM in foreground. Do not override daemonize from the Docker image.
emergency_restart_threshold = 10
emergency_restart_interval = 1m
process_control_timeout = 10s

[www]
; Official wordpress:fpm listens on port 9000 by default.
listen = 9000
listen.backlog = 2048

; Auto-sized at startup from the container's cgroup CPU/memory limits.
; Override any of these via WORDPRESS_FPM_CONF (merged after these defaults),
; or tune the inputs via FPM_WORKER_MEM_MB / FPM_RESERVED_MEM_MB /
; FPM_WORKERS_PER_CORE / FPM_MIN_CHILDREN / FPM_MAX_CHILDREN.
pm = dynamic
pm.max_children = ${max_children}
pm.start_servers = ${start_servers}
pm.min_spare_servers = ${min_spare}
pm.max_spare_servers = ${max_spare}
pm.max_requests = 500

; Kill very slow PHP requests instead of letting workers hang forever.
request_terminate_timeout = 120s

; Slow request logging.
request_slowlog_timeout = 5s
slowlog = /proc/self/fd/2

; Docker-friendly logging.
catch_workers_output = yes
decorate_workers_output = no

php_admin_value[error_log] = /proc/self/fd/2
php_admin_flag[log_errors] = on

; Useful for health checks / metrics.
pm.status_path = /fpm-status
ping.path = /fpm-ping
ping.response = pong

; WordPress only needs PHP scripts executed as PHP.
security.limit_extensions = .php

; Keep env vars available for WordPress Docker env config.
clear_env = no"

merge_and_write_config \
    "$DEFAULT_WORDPRESS_FPM_CONF" \
    "${WORDPRESS_FPM_CONF:-}" \
    "/usr/local/etc/php-fpm.d/zz-custom.conf" \
    "1" \
    "FPM pool config"
