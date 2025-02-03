FROM wordpress:6.7.1-php8.3-fpm

RUN apt update
RUN apt install -y nginx

COPY ./wp-html /var/www/html

COPY nginx.conf /etc/nginx/nginx.conf
COPY default.conf /etc/nginx/conf.d/default.conf
COPY run.sh /usr/run.sh

EXPOSE 80

CMD /usr/run.sh

