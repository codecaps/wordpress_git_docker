#!/bin/bash

docker buildx build . --platform linux/amd64 --progress=auto -t europe-west4-docker.pkg.dev/appstrax/main/wordpress:git

docker run \
--add-host host.docker.internal:host-gateway \
-e WORDPRESS_DB_HOST=host.docker.internal:3306 \
-e WORDPRESS_DB_USER='root' \
-e WORDPRESS_DB_PASSWORD='qwerty' \
-e WORDPRESS_DB_NAME='wordpress' \
-e WORDPRESS_DEBUG=true \
-p 8000:80 \
-p 9113:9113 \
-p 9253:9253 \
--name wordpress_git \
-v wordpress_uploads:/var/www/html/wp-content/uploads \
-e CACHE_TTL_SECONDS=60 \
-e CACHE_IGNORE_QUERY_PARAMS='["utm_*","fbclid"]' \
-d europe-west4-docker.pkg.dev/appstrax/main/wordpress:git
# -e CACHE_ENABLED=false \

# -e WORDPRESS_CUSTOM_INI='memory_limit = 128M
# opcache.enable = 1
# opcache.memory_consumption = 128
# opcache.interned_strings_buffer = 16
# opcache.max_accelerated_files = 10000
# opcache.validate_timestamps = 0
# opcache.revalidate_freq = 0
# opcache.enable_cli = 0
# opcache.save_comments = 1
# opcache.jit = tracing
# opcache.jit_buffer_size = 64M
# realpath_cache_ttl = 600
# output_buffering = 4096
# upload_max_filesize = 32M
# post_max_size = 40M
# max_file_uploads = 10
# max_execution_time = 60
# max_input_time = 60
# default_socket_timeout = 30
# display_errors = Off
# log_errors = On
# error_reporting = E_ALL & ~E_DEPRECATED & ~E_STRICT' \
# -e WORDPRESS_FPM_CONF='[www]
# pm = static
# pm.max_children = 8
# pm.max_requests = 500
# request_terminate_timeout = 60s' \

