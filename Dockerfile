FROM wordpress:6.9-php8.4-fpm

ARG NGINX_EXPORTER_VERSION=1.4.0
ARG FPM_EXPORTER_VERSION=2.2.0
ARG TARGETARCH=amd64

# Install nginx, curl, and Prometheus exporter binaries in a single layer.
RUN apt-get update && apt-get install -y --no-install-recommends nginx curl \
    && curl -fsSL \
       "https://github.com/nginx/nginx-prometheus-exporter/releases/download/v${NGINX_EXPORTER_VERSION}/nginx-prometheus-exporter_${NGINX_EXPORTER_VERSION}_linux_${TARGETARCH}.tar.gz" \
       | tar -xz -C /usr/local/bin nginx-prometheus-exporter \
    && curl -fsSL \
       "https://github.com/hipages/php-fpm_exporter/releases/download/v${FPM_EXPORTER_VERSION}/php-fpm_exporter_${FPM_EXPORTER_VERSION}_linux_${TARGETARCH}" \
       -o /usr/local/bin/php-fpm_exporter \
    && chmod +x /usr/local/bin/php-fpm_exporter \
    && rm -rf /var/lib/apt/lists/* \
    && apt-get clean

# Copy WordPress files (populated by the Code Capsules build pipeline).
COPY ./wp-html /var/www/html

# Copy WordPress application metrics endpoint (served via internal nginx on :8080).
COPY wp-metrics.php /var/www/html/wp-metrics.php

# Copy nginx config.
COPY nginx.conf /etc/nginx/nginx.conf
COPY default.conf /etc/nginx/conf.d/default.conf

# Copy entrypoint and startup scripts.
COPY run.sh /usr/run.sh
COPY scripts /usr/scripts
RUN chmod +x /usr/run.sh \
              /usr/scripts/configure_wordpress_custom_ini.sh \
              /usr/scripts/configure_wordpress_fpm_conf.sh \
              /usr/scripts/configure_nginx_overrides.sh

RUN mkdir -p /var/cache/nginx/wordpress \
    && chown -R www-data:www-data /var/cache/nginx

EXPOSE 80
EXPOSE 9113
EXPOSE 9253

# Health check hits the internal metrics server which proxies /fpm-ping to PHP-FPM,
# verifying that both nginx and php-fpm are alive.
HEALTHCHECK --interval=15s --timeout=5s --start-period=20s --retries=3 \
    CMD curl -sf http://127.0.0.1:8080/fpm-ping || exit 1

ENTRYPOINT ["/usr/run.sh"]
