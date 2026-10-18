#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib/merge_and_write_config.sh
source "$SCRIPT_DIR/lib/merge_and_write_config.sh"

DEFAULT_WORDPRESS_FPM_CONF='[global]
; Keep PHP-FPM in foreground. Do not override daemonize from the Docker image.
emergency_restart_threshold = 10
emergency_restart_interval = 1m
process_control_timeout = 10s

[www]
; Official wordpress:fpm listens on port 9000 by default.
listen = 9000
listen.backlog = 2048

pm = static
pm.max_children = 3
pm.max_requests = 500

request_terminate_timeout = 20s

; Slow request logging.
request_slowlog_timeout = 2s
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
clear_env = no'

merge_and_write_config \
    "$DEFAULT_WORDPRESS_FPM_CONF" \
    "${WORDPRESS_FPM_CONF:-}" \
    "/usr/local/etc/php-fpm.d/zz-custom.conf" \
    "1" \
    "FPM pool config"
