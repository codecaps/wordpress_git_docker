# Wordpress Deployments

This repository is used for Git based Code Capsules wordpress deployments.
<br>

The Dockerfile must start from a FPM wordpress image (FPM is PHP's fastcgi implementation)

We use nginx as a proxy. `default.conf` and `nginx.conf` are used as the nginx config.

`run.sh` is the file which docker rus on image start, this file will: 
<br>- copy the custom php.ini values from `$WP_CUSTOM_INI` to the `$PHP_INI_DIR/conf.d/` directory
<br>- start the nginx service
<br>- run the wordpress php-fpm start command

## Git Deployment
This is used for git based wordpress deployments.
<br>The `wp-html` folder will is populated with the contents of the git installation,this is done in the code capsules deployment pipeline, then coppied into `/var/www/html` folder.
<br>`/var/www/html/wp-content/uploads` has a volume mount to persist uploads between deployments.

We use `wordpress:6.7.1-php8.3-fpm` as the base image
