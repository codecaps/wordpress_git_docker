#!/bin/bash
set -euo pipefail

RUN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

"$RUN_DIR/scripts/configure_wordpress_custom_ini.sh"
"$RUN_DIR/scripts/configure_wordpress_fpm_conf.sh"
"$RUN_DIR/scripts/configure_nginx_overrides.sh"

nginx -t

_shutdown() {
    echo "[run] Signal received — shutting down"
    [ -n "${NGINX_PID:-}"      ] && kill -TERM "$NGINX_PID"      2>/dev/null || true
    [ -n "${NGINX_EXP_PID:-}"  ] && kill -TERM "$NGINX_EXP_PID"  2>/dev/null || true
    [ -n "${FPM_EXP_PID:-}"    ] && kill -TERM "$FPM_EXP_PID"    2>/dev/null || true
    [ -n "${CRON_LOOP_PID:-}"  ] && kill -TERM "$CRON_LOOP_PID"  2>/dev/null || true
    [ -n "${FPM_PID:-}"        ] && kill -TERM "$FPM_PID"        2>/dev/null || true
    wait 2>/dev/null || true
    exit 0
}
trap _shutdown TERM INT

nginx -g 'daemon off;' &
NGINX_PID=$!

nginx-prometheus-exporter \
    --nginx.scrape-uri="http://127.0.0.1:8080/nginx_status" \
    --web.listen-address=":9113" &
NGINX_EXP_PID=$!

php-fpm_exporter server \
    --phpfpm.scrape-uri="tcp://127.0.0.1:9000/fpm-status" \
    --web.listen-address=":9253" &
FPM_EXP_PID=$!

docker-entrypoint.sh php-fpm &
FPM_PID=$!

# Internal wp-cron trigger loop. wp-cron.php is restricted to 127.0.0.1 by
# nginx (DISABLE_PUBLIC_WP_CRON), so WordPress's own page-load-triggered
# pseudo-cron (which self-requests the public site URL) can never reach it —
# this loop calls it from inside the container instead, on the loopback
# interface nginx already trusts. Opt-in via WP_CRON_TRIGGER_ENABLED (off by
# default — this is a shared base image, and existing capsules relying on
# their own external cron trigger shouldn't get a second one silently added
# on their next image update). Tune the interval with
# WP_CRON_TRIGGER_INTERVAL_SECONDS.
wp_cron_trigger_enabled="${WP_CRON_TRIGGER_ENABLED:-false}"
if [[ "${wp_cron_trigger_enabled,,}" =~ ^(true|1|yes|on)$ ]]; then
    (
        # Signal delivery to a backgrounded shell doesn't reliably reach a
        # grandchild `sleep` — trap TERM here and kill it explicitly so
        # shutdown doesn't stall for up to a full interval.
        trap 'kill -TERM "${SLEEP_PID:-}" 2>/dev/null; exit 0' TERM
        while true; do
            curl -fsS --max-time 30 -H "Host: 127.0.0.1" \
                "http://127.0.0.1/wp-cron.php?doing_wp_cron" \
                >/dev/null || echo "[wp-cron-trigger] trigger failed" >&2
            sleep "${WP_CRON_TRIGGER_INTERVAL_SECONDS:-300}" &
            SLEEP_PID=$!
            wait "$SLEEP_PID"
        done
    ) &
    CRON_LOOP_PID=$!
fi

# Exit as soon as nginx or php-fpm dies — triggers _shutdown for the rest.
wait -n "$NGINX_PID" "$FPM_PID" 2>/dev/null || true
_shutdown
