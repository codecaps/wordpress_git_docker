# WordPress Deployments

This repository is used for Git based Code Capsules WordPress deployments.

The Dockerfile starts from `wordpress:6.8.1-php8.3-fpm` (FPM is PHP's FastCGI implementation).

We use nginx as a reverse proxy. `default.conf` and `nginx.conf` are the nginx configuration files.

## Container Startup

`run.sh` is executed on container start. It will:
- Write custom PHP ini values from `$WORDPRESS_CUSTOM_INI` to `$PHP_INI_DIR/conf.d/zz-custom.ini`
- Write custom PHP-FPM pool config from `$WORDPRESS_FPM_CONF` to `/usr/local/etc/php-fpm.d/zz-custom.conf`
- Generate nginx cache and rate-limit overrides from environment variables
- Validate nginx configuration with `nginx -t`
- Start the nginx service
- Run the WordPress PHP-FPM entrypoint
- Stop nginx when the PHP-FPM process exits

## Git Deployment

This is used for Git-based WordPress deployments.

The `wp-html` folder is populated with the contents of the Git installation (done in the Code Capsules deployment pipeline), then copied into `/var/www/html`.

`/var/www/html/wp-content/uploads` has a volume mount to persist uploads between deployments.

## Environment Variables

### Required WordPress Variables

| Variable | Description |
|----------|-------------|
| `WORDPRESS_DB_HOST` | Database host (e.g., `host:3306`) |
| `WORDPRESS_DB_USER` | Database username |
| `WORDPRESS_DB_PASSWORD` | Database password |
| `WORDPRESS_DB_NAME` | Database name |

### Performance Tuning Variables

#### `WORDPRESS_CUSTOM_INI`

Custom PHP ini settings. Recommended for 2GB RAM / 1 CPU:

```
memory_limit = 128M
opcache.enable = 1
opcache.memory_consumption = 128
opcache.interned_strings_buffer = 16
opcache.max_accelerated_files = 10000
opcache.validate_timestamps = 0
opcache.revalidate_freq = 0
opcache.enable_cli = 0
opcache.save_comments = 1
opcache.jit = tracing
opcache.jit_buffer_size = 64M
realpath_cache_ttl = 600
output_buffering = 4096
upload_max_filesize = 32M
post_max_size = 40M
max_file_uploads = 10
max_execution_time = 60
max_input_time = 60
default_socket_timeout = 30
display_errors = Off
log_errors = On
error_reporting = E_ALL & ~E_DEPRECATED & ~E_STRICT
```

#### `WORDPRESS_FPM_CONF`

Custom PHP-FPM pool configuration. Recommended for 2GB RAM / 1 CPU:

```
[www]
pm = static
pm.max_children = 8
pm.max_requests = 500
request_terminate_timeout = 60s
```

**Scaling guide:**

| RAM | CPU | `pm.max_children` |
|-----|-----|-------------------|
| 512MB | 0.5 | 3 |
| 1GB | 1 | 5 |
| 2GB | 1 | 8 |
| 4GB | 2 | 16 |

### Nginx Runtime Variables

#### `CACHE_ENABLED`

- Controls whether FastCGI page caching is active.
- Default: `true`
- Truthy values: `true`, `1`, `yes`, `on`
- Any other value disables caching (bypass-only mode).

#### `CACHE_TTL_MINUTES`

- Cache TTL (in minutes) for `200/301/302` responses.
- Default: `10`
- Must be a positive integer. Invalid values fall back to default.

#### `RATE_LIMIT_NORMAL_ROUTES_RPM`

- Requests-per-minute limit for `normal_routes`.
- Default: `120`
- Must be a positive integer.

#### `RATE_LIMIT_PROTECTED_ROUTES_RPM`

- Requests-per-minute limit for `protected_routes`.
- Default: `30`
- Must be a positive integer.

#### `RATE_LIMIT_API_ROUTES_RPM`

- Requests-per-minute limit for `api_routes`.
- Default: `60`
- Must be a positive integer.

### Startup Script Layout

- `run.sh` orchestrates container startup.
- `scripts/configure_wordpress_custom_ini.sh` handles `WORDPRESS_CUSTOM_INI`.
- `scripts/configure_wordpress_fpm_conf.sh` handles `WORDPRESS_FPM_CONF`.
- `scripts/configure_nginx_overrides.sh` generates env-driven nginx override files.
- `scripts/lib/merge_and_write_config.sh` contains shared merge logic.

## Optimizations Included

- **OPcache with JIT**: Reduces CPU usage by 30-50%
- **Gzip compression**: Reduces response sizes by 60-80%
- **Static file caching**: 30-day browser cache for assets
- **Security headers**: X-Frame-Options, X-Content-Type-Options
- **PHP execution in uploads blocked**: Prevents malicious uploads
- **Sensitive files blocked**: wp-config.php, .git, .htaccess
