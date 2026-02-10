#!/bin/bash

# Write custom PHP ini values
if [ "$WORDPRESS_CUSTOM_INI" ]; then
    echo "Writing custom ini values"
    printf "$WORDPRESS_CUSTOM_INI" > $PHP_INI_DIR/conf.d/zz-custom.ini
fi

# Write custom PHP-FPM pool config
if [ "$WORDPRESS_FPM_CONF" ]; then
    echo "Writing custom FPM pool config"
    printf "$WORDPRESS_FPM_CONF" > /usr/local/etc/php-fpm.d/zz-custom.conf
fi

set +e
service nginx start
docker-entrypoint.sh php-fpm
service nginx stop
