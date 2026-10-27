# Resource-aware sizing: investigation and load-test record (2026-10-27)

This note records why the image now sizes PHP, PHP-FPM and nginx to the capsule's
cgroup limits, how the numbers were chosen, and what the load tests showed. The model
itself is documented in the README ("Resource-aware sizing"); this is the evidence.

## Trigger

A production git-based WordPress capsule (a 15-plugin multilingual site: ACF Pro,
TranslatePress, SEOPress Pro, WP Activity Log, a custom product-finder theme, Redis
object cache) was OOM-killed during a traffic burst. Its access logs show the last
200 seconds before the kill: ~10 requests/s, median response 2.9 s, p90 9.4 s.

The image shipped one fixed configuration for every capsule size:

| Setting | Old value | Worst case on the 1 GB Premium plan |
|---|---|---|
| `pm.max_children` | 24 | 24 workers |
| `memory_limit` | 256M | 24 × 256M = 6 GB of PHP heap |
| `opcache.memory_consumption` | 256M | more than the whole Basic plan (0.28 GB) |
| nginx `worker_processes` | `auto` (one per **host** core) | 4 on these nodes; dozens on large nodes |

Nothing inside the container reports its limits: `nproc` and `/proc/meminfo` describe the
node, so the only correct source is the cgroup.

## Method

A test capsule on cc-proxmox was restored from the production backups (database
398 MB, uploads 21 MB), the domain rewritten with `wp search-replace`, and the same
git repo built into the image. Load came from a k6 Job inside the cluster replaying a
weighted corpus of the 1,766 distinct production URLs (560 of them product-search
queries), with a random public `X-Forwarded-For` per request so nginx's per-IP limits
saw real-world fan-out. Each run ramped 2 → 5 → 10 → 20 → 80 requests/s over ~9 minutes.
A sampler read the pod's cgroup memory, per-worker private RSS (`RssAnon`) and FPM
status every 4 s.

## Measurements

Per-worker private memory on this heavy site, across all runs: **28–48 MB average,
60 MB peak**. The 256M `memory_limit` was never approached by a front-end request; 128M
produced no "Allowed memory size" errors in any run.

Every run below is the same ~6–10 minute replay ramping to 80 req/s (40 on Basic).
"Served" is the number of HTML pages that completed with 200; everything else was a
30 s client timeout (old image) or an immediate 429 (new image).

### Test cluster (cc-proxmox, final image)

| Image | Plan | Peak memory | Workers | Served | Served p50 / max | FPM 30 s after burst |
|---|---|---|---|---|---|---|
| old defaults | Premium 1 GB / 25% | **843 MB (88%)**, still climbing | 24 | ~1% of 6,712 requests | 10 s / 30 s+ | unresponsive |
| final | Standard 0.6 GB / 15% | 213 MB (37%) | 2 | 121 | 12 s / 28 s | idle, queue 0 |
| final | Premium 1 GB / 25% | 190 MB (20%) | 3 | 274 | 9 s / 14.5 s | idle, queue 0 |
| final | Basic 0.28 GB / 7% | 157 MB (59%) | 2 | 64 | 25 s / 37 s | idle, queue 0 |
| final | Custom 4 GB / 1 vCPU | 436 MB (11%) | 12 | 837 | 9 s / 17.6 s | idle, queue 0 |
| final + `CACHE_TTL_SECONDS=60` | Premium | 292 MB (31%) | 3 | 275 (35 cache hits) | 8.5 s / 13.9 s | idle |

### Local Docker lab (same site, same DB, Apple Silicon, `--memory`/`--cpus` per plan)

| Image | Plan | Peak memory | Workers | Served | Served p50 / max | Outcome |
|---|---|---|---|---|---|---|
| old defaults | Standard 0.6 GB / 15% | **560 MB (98%)** | 24 | 6 | 85 s / 113 s | **OOM-killed 5×** (`oom_killed=true`), FPM dead after |
| final | Standard 0.6 GB / 15% | 231 MB (40%) | 2 | 74 | 33 s / 109 s (16-deep queue) | no OOM, recovered |
| final (4/worker queue) | Premium 1 GB / 25% | 234 MB (25%) | 3 | 163 | 11 s / 43 s | no OOM, recovered |
| final | Basic 0.28 GB / 7% | 214 MB (80%) | 2 | 0 (no page finishes in 30 s at 0.07 vCPU) | – | no OOM |
| final | Custom 2 GB / 1 vCPU | 461 MB (24%) | 11 | 1,252 | 5.4 s / 14.6 s | no OOM, recovered |

The page-cache run is the surprise: it changed nothing, because the replayed production
burst was 1,766 distinct URLs in 2,000 requests (88% unique, across 20 locales and
product-search filter permutations). That is crawler/scraper traffic; a 60 s page cache
cannot absorb it, and neither could any worker count. For this site the effective
mitigations are the in-flight cap (the capsule stays up and recovers) and keeping
crawlers out (robots, `X-Robots-Tag`, user-agent blocking), both of which were applied.

Findings along the way, each fixed in its own commit:

1. **Memory.** The old pool used 82–88% of a 1 GB capsule under load for no benefit:
   the capsule is CPU-bound at 0.25 vCPU, so 14 of the 24 workers were merely waiting
   for CPU while holding ~35 MB each. One heavier burst (admin work raises
   `memory_limit` to 256M) tips this over the limit, which is what production saw; on
   the 0.6 GB plan the same defaults were OOM-killed within minutes in the lab.
2. **File descriptors.** With `worker_processes` sized to 1, the container's 1024 soft
   fd limit capped nginx at ~500 in-flight proxied requests; past that `accept()` failed
   and nginx returned 500 without touching PHP. `auto` had hidden this by running four
   workers. Fixed with `worker_rlimit_nofile 65536` (the hard limit in capsules is
   524288) and `worker_connections 16384`.
3. **Unbounded queueing.** nginx accepted every request and queued it for a worker.
   On a 2-worker capsule a burst left hundreds of doomed requests in the FPM backlog,
   each burning ~60 s of a 0.15-vCPU budget after its client had long gone; PHP-FPM
   was still unresponsive to its own status endpoint eight minutes after the burst
   ended. Fixed with a capsule-wide `limit_conn` sized to `pm.max_children × 4`
   (first tried × 8: on 2 workers at 0.15 vCPU the admitted requests then waited
   33–109 s for a worker, longer than any visitor stays; throughput is CPU-bound
   whatever the depth, so the shallower queue only trades waiting for fast 429s).
4. **Where `limit_conn` is evaluated.** nginx evaluates connection limits once per
   request, in the first location it matches; a pretty URL lands in `location /` and
   only reaches the PHP handler via a `try_files` internal redirect, so a cap declared
   in the PHP handler never fired for page views. The cap is now included in every
   PHP-bound location. Verified in a container with a slow `index.php`: a 30-request
   burst against a 24-slot cap serves 24 and answers 429 to 6 within a millisecond.
5. **Slow-request log.** `request_slowlog_timeout` needs `ptrace`, which the capsule
   security context forbids; every slow request only logged
   `failed to ptrace(ATTACH)`. Disabled.
6. **Override composition.** Pinning `pm.max_children` below the old static spare
   values made PHP-FPM refuse to start (`max_spare_servers > max_children`). A pinned
   `pm.max_children` now re-derives the spare pool, and a pinned `memory_limit` in
   `WORDPRESS_CUSTOM_INI` feeds back into the worker budget.

## What the sizing produces

| Plan | Memory | CPU | `memory_limit` | opcache | `pm.max_children` | in-flight cap | nginx workers |
|---|---|---|---|---|---|---|---|
| Basic | 0.28 GB | 7% | 128M | 64M | 2 (floor) | 8 | 1 |
| Standard | 0.6 GB | 15% | 128M | 64M | 2 | 8 | 1 |
| Premium | 1 GB | 25% | 128M | 112M | 3 | 12 | 1 |
| Custom | 2 GB | 1 | 256M | 256M | 12 | 48 | 1 |
| Custom | 4 GB | 2 | 256M | 256M | 24 | 96 | 2 |

## What the sizing cannot fix

At 0.15–0.25 vCPU an uncached page of this site costs 1.5–3 s of CPU, so the plans
serve well under 1 page/s uncached, regardless of worker count. The production burst
(10 req/s) is only survivable with page caching: `CACHE_TTL_SECONDS` (nginx FastCGI
cache) is off unless set. The sizing turns "OOM-kill and restart" into "answer 429 past
capacity and recover instantly", which is the correct failure mode, but capacity itself
comes from caching or a bigger plan.

## Verification record

- `bash tests/run.sh` — 1,500+ assertions over cgroup v1/v2 detection, the sizing
  model (invariants across 160 size/CPU combinations), and the configure scripts
  including customer overrides.
- Local `docker run --memory --cpus` boots at 0.6 GB/0.15, 1 GB/0.25, 4 GB/2 and with
  no limits (host fallback), with and without overrides.
- The dashboard's "Custom php.ini Config" editor: a saved `memory_limit = 192M` /
  `max_input_vars = 5000` reached the pod's env secret, the merged ini and the PHP
  runtime, was fed back into the sizing (`worker_budget=96M`), survived a rebuild, and
  clearing it restored the defaults.

Dashboard observation (not in this repo): after clearing the "Custom php.ini Config"
editor, the stored `WORDPRESS_CUSTOM_INI` is an empty string, and the environment
variable editor then refuses to save anything ("One or more environment variables are
invalid") until the ini has a non-empty value again.
