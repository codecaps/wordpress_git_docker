# WordPress Deployments

This repository is the base Docker image for Git-based Code Capsules WordPress deployments.

The Dockerfile starts from `wordpress:7.1.3-php8.5-fpm`. Nginx acts as a reverse proxy in front of PHP-FPM, both running in the same container.

---

## Container Startup

`run.sh` is executed on container start. It:

1. Reads the container's cgroup CPU and memory limits and sizes PHP, PHP-FPM and nginx to them (logged as `[sizing]` lines — see [Resource-aware sizing](#resource-aware-sizing))
2. Writes the sized PHP ini defaults merged with `$WORDPRESS_CUSTOM_INI` to `$PHP_INI_DIR/conf.d/zz-custom.ini`
3. Writes the sized PHP-FPM pool config merged with `$WORDPRESS_FPM_CONF` to `/usr/local/etc/php-fpm.d/zz-custom.conf`
4. Generates nginx config fragments from environment variables (worker count, rate limits, cache, security headers, etc.)
5. Validates nginx configuration with `nginx -t`
6. Starts nginx, nginx-prometheus-exporter, php-fpm_exporter, and php-fpm as supervised background processes
7. Shuts everything down cleanly on SIGTERM

Prometheus metrics are exposed on ports **9113** (nginx) and **9253** (PHP-FPM).

---

## Git Deployment

The `wp-html` folder is populated with the contents of the Git installation (done in the Code Capsules deployment pipeline), then copied into `/var/www/html`.

`/var/www/html/wp-content/uploads` has a volume mount to persist uploads between deployments.

---

## Environment Variables

### Required WordPress Variables

| Variable | Description |
|---|---|
| `WORDPRESS_DB_HOST` | Database host (e.g., `host:3306`) |
| `WORDPRESS_DB_USER` | Database username |
| `WORDPRESS_DB_PASSWORD` | Database password |
| `WORDPRESS_DB_NAME` | Database name |

### WordPress Configuration

#### `WORDPRESS_CONFIG_EXTRA`

Arbitrary PHP injected directly into `wp-config.php` by the upstream WordPress Docker entrypoint. Use this for WordPress constants that belong in `wp-config.php`:

```
WORDPRESS_CONFIG_EXTRA=define('DISABLE_WP_CRON', true);
define('FORCE_SSL_ADMIN', true);
define('WP_MEMORY_LIMIT', '256M');
define('WP_MAX_MEMORY_LIMIT', '512M');
```

> **Recommended:** Set `define('DISABLE_WP_CRON', true);` so WordPress doesn't waste a
> request self-triggering cron via its public URL (which `DISABLE_PUBLIC_WP_CRON` blocks
> anyway). If this capsule needs scheduled posts / cron-driven plugin tasks to actually
> run, also set `WP_CRON_TRIGGER_ENABLED=true` below — `run.sh` will then drive cron
> internally, no platform-level CronJob or public wp-cron.php required. It's opt-in
> (off by default) since this is a shared base image.

#### `WORDPRESS_CUSTOM_INI`

Custom PHP ini settings, merged **over** the sized defaults (a key you set replaces
the default; keys you don't set keep their sized value; unknown keys are appended).
Nothing needs to be set for a capsule to be correctly sized — this is for the
exceptions. Examples:

```ini
; A plugin that needs more than the sized per-request limit:
memory_limit = 512M

; Theme with very large forms:
max_input_vars = 5000

; Immutable image where plugins/themes never update at runtime:
opcache.validate_timestamps = 0
```

> **Note:** `upload_max_filesize` and `post_max_size` default to `MAX_UPLOAD_SIZE`. Override here only if you need them to differ from the nginx limit.

> **Note:** a `memory_limit` set here is fed back into the sizing: the worst case of every
> worker grows with it, so the worker pool shrinks accordingly (see the `[sizing]` boot log).

#### `WORDPRESS_FPM_CONF`

Custom PHP-FPM pool configuration, merged over the sized defaults the same way (per
`[section]`). Only needed to pin a pool by hand. A `pm.max_children` set here re-derives
`pm.start_servers` / `pm.min_spare_servers` / `pm.max_spare_servers` from the pinned value
(PHP-FPM refuses to start when `max_spare_servers` exceeds `max_children`), unless you set
those too:

```ini
[www]
pm = static
pm.max_children = 8
pm.max_requests = 500
request_terminate_timeout = 60s
```

> **Security note:** `clear_env = no` is set so WordPress can read `WORDPRESS_DB_HOST` etc. via `getenv()`. This also means **all** environment variables in the container are visible to PHP code. Do not inject secrets as env vars that WordPress plugins should not access.

---

### Resource-aware sizing

Kubernetes enforces a capsule's scale with cgroup limits, but nothing inside the
container reports them: `nproc` and `/proc/meminfo` describe the *node*. The image
therefore reads its own cgroup (v2 or v1) at startup and derives the PHP, PHP-FPM and
nginx defaults from the real limits, so one image is safe on a 0.28 GB Basic capsule and
uses all of a multi-GB one. The sizing is logged on every boot:

```
[sizing] Container limits (cgroup): memory=953M cpu=250m
[sizing]   php: memory_limit=128M opcache=112M interned_strings=8M
[sizing]   php-fpm: max_children=3 (memory-bound=10, cpu-bound=3, worker_budget=64M, reserved=139M) start=1 spare=1-2
[sizing]   nginx: worker_processes=1
```

The model (`scripts/lib/resource_sizing.sh`), all in MiB:

| Setting | Rule | Why |
|---|---|---|
| `memory_limit` | 128M below 1.5 GB, 256M above | Per-request cap. WordPress front-end requests peak at 40–70 MB even on heavy sites; WordPress raises the limit itself to `WP_MAX_MEMORY_LIMIT` (256M) for admin work. |
| `opcache.memory_consumption` | memory ÷ 8, clamped 64–256, rounded to 16 | Shared segment, charged once. Core + a typical plugin set compiles to 40–120 MB. |
| `opcache.interned_strings_buffer` | 8 / 16 / 32 by opcache size | |
| reserved | 80 + memory ÷ 16 | nginx, the two exporters, the FPM master, and page-cache headroom. |
| worker budget | `memory_limit` ÷ 2 (`PHP_WORKER_MEMORY_MB`) | Private memory budgeted per FPM worker. Measured 35 MB average / 56 MB peak per worker on a 15-plugin multilingual site. |
| `pm.max_children` | min( (memory − reserved − opcache) ÷ worker budget, ceil(CPU × `PHP_FPM_WORKERS_PER_CPU`) ), clamped 2–64 | The memory bound keeps the pool inside the container; the CPU bound stops forking workers the quota cannot run (they only add memory and contention — requests wait in the listen backlog instead). |
| `pm.start_servers` / spare | ⅓ / ¼ – ½ of `max_children` | |
| nginx `worker_processes` | ceil(CPU), clamped 1–4 | `auto` starts one worker per *host* core. |
| in-flight PHP requests | `pm.max_children` × 8 (`PHP_INFLIGHT_PER_WORKER`), clamped 16–1024 | Concurrent PHP requests nginx accepts (all clients together) before answering `429`. Past the FPM pool every request waits in a queue; without a cap a burst queues thousands of requests that each hold a worker for a minute, and the capsule stays unresponsive for hours after the burst. |

What that produces for the standard plans:

| Plan | Memory | CPU | `memory_limit` | opcache | `pm.max_children` | in-flight cap | nginx workers |
|---|---|---|---|---|---|---|---|
| Basic | 0.28 GB | 7% | 128M | 64M | 2 (floor) | 16 | 1 |
| Standard | 0.6 GB | 15% | 128M | 64M | 2 | 16 | 1 |
| Premium | 1 GB | 25% | 128M | 112M | 3 | 24 | 1 |
| Custom | 2 GB | 1 | 256M | 256M | 12 | 96 | 1 |
| Custom | 4 GB | 2 | 256M | 256M | 24 | 192 | 2 |
| Custom | 8 GB | 4 | 256M | 256M | 48 | 384 | 4 |

> Basic cannot fit even two workers inside its budget; the floor of 2 is applied so the
> site still serves, at the cost of a thin margin. WordPress with more than a handful of
> plugins should run on Standard or above.

Tuning knobs — rarely needed, since any output can also be pinned directly through
`WORDPRESS_CUSTOM_INI` / `WORDPRESS_FPM_CONF`:

| Variable | Default | Description |
|---|---|---|
| `PHP_WORKER_MEMORY_MB` | `memory_limit` ÷ 2 | Private memory budgeted per FPM worker. Raise it for sites whose requests routinely peak high (WooCommerce with many extensions); lower it for lean sites to get more workers. |
| `PHP_FPM_WORKERS_PER_CPU` | `12` | Worker oversubscription per core. PHP is CPU-bound once OPcache is warm, so more only helps if requests spend most of their time waiting on a slow database or external API. |
| `PHP_INFLIGHT_PER_WORKER` | `8` | Queued-plus-active PHP requests allowed per worker before nginx answers `429`. Raise it if your pages are fast and you would rather queue than shed. |

Without a cgroup limit (local `docker run` without `--memory`/`--cpus`) the sizing
falls back to the host's memory and CPU count and says so in the log.

Run the sizing tests with `bash tests/run.sh` (bash 4+).

---

### Upload Size

#### `MAX_UPLOAD_SIZE`

Controls `client_max_body_size` in nginx **and** `upload_max_filesize` / `post_max_size` in PHP, keeping them in sync.

- Default: `64M`
- Accepts: `64M`, `128M`, `256M`, etc.

This is the single knob for upload size. Do not set `upload_max_filesize` in `WORDPRESS_CUSTOM_INI` to a value larger than this, or nginx will silently reject uploads with 413.

---

### Caching

#### `CACHE_TTL_SECONDS`

Enables FastCGI page caching and sets TTL in seconds. Must be a positive integer.

- Default: unset (caching disabled)
- Example: `CACHE_TTL_SECONDS=60` enables caching with 60s TTL
- Example: `CACHE_TTL_SECONDS=600` enables caching with 10-minute TTL

If this variable is not set, nginx runs with caching disabled (`fastcgi_cache_bypass 1` / `fastcgi_no_cache 1`).

> **Which strategy should I use?**
>
> - Start with `CACHE_TTL_SECONDS=60` for most content sites.
> - Use a higher value such as `CACHE_TTL_SECONDS=600` for mostly-static sites.
> - Leave `CACHE_TTL_SECONDS` unset for WooCommerce, membership/LMS, real-time dashboards, or when a WordPress cache plugin manages page caching.

#### `CACHE_IGNORE_QUERY_PARAMS`

Normalizes the FastCGI cache key by ignoring matching query parameter **names** (WordPress still receives the full query string). Requires `CACHE_TTL_SECONDS` to be set. If unset or `[]`, the cache key uses the full `$request_uri` (default).

- Format: JSON array of strings, e.g. `'["utm_*","fbclid"]'`
- Wildcards: `*` in a pattern matches any characters in the parameter name (e.g. `utm_*` matches `utm_term`, `utm_source`)
- Allowed characters per pattern: `A–Z`, `a–z`, `0–9`, `_`, `*`, `-`

Example with `CACHE_IGNORE_QUERY_PARAMS='["utm_*"]'`:

| Request | Cache behavior |
|---|---|
| `GET /page/1?utm_term=xyz` | MISS — rendered and stored |
| `GET /page/1?utm_term=abc` | HIT — same cache entry as above |
| `GET /page/1` | HIT — same cache entry |
| `GET /page/1?page=2&utm_term=xyz` | Key includes `page=2` only (utm params stripped from key) |

Non-ignored query parameters still differentiate cache entries. Parameter order in the URL is not normalized.

---

### Rate Limiting

| Variable | Default | Description |
|---|---|---|
| `RATE_LIMIT_NORMAL_ROUTES_RPM` | `120` | Req/min per IP for public routes |
| `RATE_LIMIT_PROTECTED_ROUTES_RPM` | `30` | Req/min per IP for wp-admin, wp-login |
| `RATE_LIMIT_API_ROUTES_RPM` | `60` | Req/min per IP for /wp-json/ |
| `RATE_LIMIT_MAX_CONN_PER_IP` | `30` | Max concurrent connections per IP |

In addition to these per-IP limits, PHP routes have a capsule-wide cap on concurrent
requests sized to the PHP-FPM pool (see [Resource-aware sizing](#resource-aware-sizing));
requests past it also get `429`.

All limits are **per client IP**. The client IP is resolved from `X-Forwarded-For`
(`real_ip_recursive on`), trusting private intermediary ranges plus Cloudflare's
edge ranges — see [Real Client IP & Cloudflare](#real-client-ip--cloudflare). If
the true client IP is not resolved correctly, every visitor shares one bucket and
trips these limits with spurious `429`s.

---

### Real Client IP & Cloudflare

nginx resolves the real client IP from `X-Forwarded-For` and uses it as the key for
all rate limits, the per-IP connection limit, access logs, and the IP passed to
WordPress (`REMOTE_ADDR` / `X-Real-IP`). `set_real_ip_from` in `nginx.conf` trusts:

- Private intermediary ranges (`10/8`, `172.16/12`, `192.168/16`) — Traefik / k8s LB / VPC.
- **Cloudflare's published edge ranges**, baked into the image at build time.

Cloudflare support is **automatic** — no env var. When the container is proxied by
Cloudflare, the edge IPs (which are public) appear in `X-Forwarded-For`. Trusting
them lets recursion walk past the edge to the real visitor. Without this, recursion
would stop at a Cloudflare IP and **collapse every visitor onto a handful of edge
IPs**, tripping the per-IP rate and connection limits. When Cloudflare is not in
front, trusting these ranges is harmless.

The ranges are fetched from `cloudflare.com/ips-v4` and `ips-v6` during `docker build`.
**Rebuild the image to refresh them.** If the fetch fails at build time, a
version-controlled snapshot (`cloudflare_ips.fallback.conf`) is used and a warning
is logged.

> ⚠️ **Security:** Trusting Cloudflare's *public* ranges means a client that can
> reach the origin **directly** (bypassing Cloudflare) could forge `X-Forwarded-For`
> to spoof or rotate client IPs — evading rate limits or framing another IP. Lock the
> origin to Cloudflare only: edge IP allowlist at your load balancer, Authenticated
> Origin Pulls, or a Cloudflare Tunnel.

---

### Security & Behaviour

| Variable | Default | Description |
|---|---|---|
| `XMLRPC_ENABLED` | `false` | Set to `true` to enable XML-RPC (Jetpack, WP mobile app, external publishing) |
| `DISABLE_PUBLIC_WP_CRON` | `true` | Restrict `wp-cron.php` to `127.0.0.1`. Triggered internally instead — see `WP_CRON_TRIGGER_ENABLED`. |
| `WP_CRON_TRIGGER_ENABLED` | `false` | Opt-in: `run.sh` runs a loop that calls `wp-cron.php` over `127.0.0.1` on an interval, since `DISABLE_PUBLIC_WP_CRON` blocks WordPress's own public-URL self-trigger. Set to `true` on any capsule that needs scheduled posts / cron-driven plugin tasks to actually run. |
| `WP_CRON_TRIGGER_INTERVAL_SECONDS` | `300` | Seconds between internal `wp-cron.php` triggers. |
| `SESSION_COOKIE_SECURE` | `1` | PHP `session.cookie_secure`. Set to `0` for local HTTP development. |
| `CSP_HEADER` | permissive default | Full `Content-Security-Policy` header value. Set to empty string to disable. |
| `DEBUG_HEADERS` | `false` | Set to `true` to expose `X-Cache` response header (reveals cache HIT/MISS/BYPASS). |

Default CSP:
```
default-src 'self' 'unsafe-inline' 'unsafe-eval' data: blob: https:; frame-ancestors 'self';
```

---

### Nginx Customisation

#### `NGINX_EXTRA_CONF`

Raw nginx config injected into the `server {}` block before the PHP handler. Useful for custom proxy rules, headless WordPress API routes, WooCommerce custom endpoints.

```
NGINX_EXTRA_CONF=location /custom-api/ { proxy_pass http://internal-service:8080/; }
```

---

### Prometheus Metrics (Build-time)

| Variable | Default | Description |
|---|---|---|
| `NGINX_EXPORTER_VERSION` | `1.4.0` | Build-time: nginx-prometheus-exporter version |
| `FPM_EXPORTER_VERSION` | `2.2.0` | Build-time: php-fpm_exporter version |
| `TARGETARCH` | `amd64` | Build-time: target CPU architecture (`amd64`, `arm64`) |

---

## Prometheus Metrics

The container exposes two Prometheus metrics ports. No sidecar required.

| Port | Exporter | Key metrics |
|---|---|---|
| `9113` | nginx-prometheus-exporter | `nginx_connections_active`, `nginx_http_requests_total`, `nginx_connections_waiting` |
| `9253` | php-fpm_exporter | `phpfpm_listen_queue`, `phpfpm_max_children_reached_total`, `phpfpm_active_processes`, `phpfpm_slow_requests_total` |

WordPress application metrics (post counts, user counts, autoloaded options) are available at `http://127.0.0.1:8080/wp-metrics` from inside the container only.

**Recommended Prometheus alerts:**

```yaml
- alert: FPMWorkersExhausted
  expr: phpfpm_listen_queue > 0
  for: 1m

- alert: FPMMaxChildrenHit
  expr: increase(phpfpm_max_children_reached_total[5m]) > 0

- alert: FPMNoIdleWorkers
  expr: phpfpm_idle_processes == 0
  for: 2m

- alert: WordPressAutoloadBloat
  expr: wordpress_autoloaded_options_bytes > 5e6
```

---

## Redis Object Cache

The **PhpRedis** C extension is baked into this image (see the `pecl install redis`
layer in the `Dockerfile`). It is significantly faster than the pure-PHP Predis
client because every `wp_cache_*` and transient call is a Redis round-trip, and
PhpRedis does the protocol/serialization work in C. To use Redis for object caching:

1. Install and activate the [Redis Cache](https://wordpress.org/plugins/redis-cache/) plugin.
2. Set constants via `WORDPRESS_CONFIG_EXTRA`:
   ```
   WORDPRESS_CONFIG_EXTRA=define('WP_REDIS_CLIENT', 'phpredis');
   define('WP_REDIS_HOST', getenv('REDIS_HOST'));
   define('WP_REDIS_PORT', 6379);
   define('WP_REDIS_PREFIX', 'mysite_');
   define('WP_REDIS_TIMEOUT', 1);
   define('WP_REDIS_READ_TIMEOUT', 1);
   ```

> **Client selection:** the Redis Cache drop-in auto-selects PhpRedis when the
> extension is present, so `WP_REDIS_CLIENT` is optional — but setting it explicitly
> documents intent and prevents a silent fall back to Predis if the extension ever
> fails to load.

> **Fail fast:** keep `WP_REDIS_TIMEOUT`/`WP_REDIS_READ_TIMEOUT` low (1s). Because
> Redis sits on the critical path of every request, a slow/unreachable Redis should
> error quickly rather than hang PHP-FPM workers. (These are already the drop-in
> defaults; setting them is belt-and-suspenders.)

> **Note:** the free Redis Cache drop-in opens a fresh (non-persistent) connection
> per request for single-node setups — `WP_REDIS_PERSISTENT`/`pconnect` only applies
> to its cluster path. The per-request `connect()` to a local Redis is one cheap
> round-trip; persistent connections are an Object Cache Pro feature.

> **Multi-tenancy:** Always set `WP_REDIS_PREFIX` to a unique value per site when multiple sites share a Redis instance. Without it, two WordPress sites will corrupt each other's object cache.

---

## Startup Script Layout

| Script | Purpose |
|---|---|
| `run.sh` | Orchestrates startup; loads the sizing, supervises nginx, exporters, and php-fpm |
| `scripts/configure_wordpress_custom_ini.sh` | Merges `WORDPRESS_CUSTOM_INI` with the sized defaults |
| `scripts/configure_wordpress_fpm_conf.sh` | Merges `WORDPRESS_FPM_CONF` with the sized defaults |
| `scripts/configure_nginx_overrides.sh` | Generates all dynamic nginx config fragments (incl. `worker_processes`) |
| `scripts/lib/merge_and_write_config.sh` | Shared awk-based merge logic |
| `scripts/lib/container_resources.sh` | Reads the container's cgroup (v1/v2) CPU and memory limits |
| `scripts/lib/resource_sizing.sh` | Derives the PHP / PHP-FPM / nginx sizing from those limits |
| `tests/run.sh` | Shell test suite for the detection, the sizing model and the configure scripts |

---

## Optimisations Included

- **Resource-aware sizing**: PHP `memory_limit`, OPcache, the PHP-FPM worker pool and nginx workers are derived from the capsule's real cgroup limits, so the container cannot over-commit its memory and be OOM-killed under load
- **OPcache**: reduces CPU usage on repeated requests
- **Gzip compression**: reduces response sizes by 60–80%
- **Static file caching**: 30-day browser cache for assets; 1h for XML/txt
- **FastCGI page cache**: opt-in via `CACHE_TTL_SECONDS`, bypassed for logged-in users, carts, admin
- **Security headers**: HSTS, CSP, X-Frame-Options, X-Content-Type-Options, Referrer-Policy, Permissions-Policy, X-Permitted-Cross-Domain-Policies
- **PHP execution blocked** in uploads, cache, and upgrade directories
- **Sensitive files blocked**: `wp-config.php`, `debug.log`, `.env`, `.git`, `wp-config-sample.php`, plugin/theme readme files, `wp-includes/*.php`
- **Rate limiting**: three configurable zones (normal, protected, API) plus per-IP connection limit, keyed on the real client IP behind Traefik/Cloudflare
- **Cloudflare-aware real IP**: edge ranges baked at build so XFF recursion resolves the true visitor IP, preventing spurious 429s
- **Prometheus metrics**: in-container nginx and PHP-FPM exporters, no sidecar required
