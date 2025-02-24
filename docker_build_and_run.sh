
docker buildx build . --platform linux/amd64 --progress=auto -t europe-west4-docker.pkg.dev/appstrax/main/wordpress:git

docker run \
--add-host host.docker.internal:host-gateway \
-e WORDPRESS_DB_HOST=host.docker.internal:3306 \
-e WORDPRESS_DB_USER='root' \
-e WORDPRESS_DB_PASSWORD='qwerty' \
-e WORDPRESS_DB_NAME='wordpress' \
-e WORDPRESS_DEBUG=true \
-p 8000:80 \
--name wordpress_git \
-v wordpress_uploads:/var/www/html/wp-content/uploads \
-e WP_CUSTOM_INI='upload_max_filesize = 64M\npost_max_size = 64M\nmax_execution_time = 300' \
-d europe-west4-docker.pkg.dev/appstrax/main/wordpress:git
