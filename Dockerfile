FROM wordpress:6.8.1-php8.3-fpm

# Install nginx
RUN apt-get update && apt-get install -y --no-install-recommends nginx \
    && rm -rf /var/lib/apt/lists/* \
    && apt-get clean

# Copy WordPress files
COPY ./wp-html /var/www/html

# Copy nginx config
COPY nginx.conf /etc/nginx/nginx.conf
COPY default.conf /etc/nginx/conf.d/default.conf

# Copy entrypoint
COPY run.sh /usr/run.sh
RUN chmod +x /usr/run.sh

EXPOSE 80

ENTRYPOINT ["/usr/run.sh"]
