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

Per-worker private memory on this heavy site, across all runs: **28–43 MB average,
60 MB peak**. The 256M `memory_limit` was never approached by a front-end request; 128M
produced no "Allowed memory size" errors in any run.

| Run | Image | Plan | Peak pod memory | FPM workers | Outcome |
|---|---|---|---|---|---|
| baseline | old defaults | Premium 1 GB / 25% | **843 MB (88%)** | 24 | no OOM in 10 min, memory still climbing; 99% of requests timed out |
| baseline hammer | old defaults | Premium 1 GB / 25% | 778 MB (82%) | 24 | same |
| sized v2 | sizing only | Standard 0.6 GB / 15% | 172 MB (30%) | 2 | no OOM; 2,468 × HTTP 500 from nginx `accept4() … Too many open files` |
| sized v3 | + fd limit, + cap in PHP handler only | Standard 0.6 GB / 15% | 175 MB (31%) | 2 | no OOM, no 500s; cap never fired (see below) |

Findings along the way, each fixed in its own commit:

1. **Memory.** The old pool used 82–88% of a 1 GB capsule under load for no benefit:
   the capsule is CPU-bound at 0.25 vCPU, so 14 of the 24 workers were merely waiting
   for CPU while holding ~35 MB each. One heavier burst (admin work raises
   `memory_limit` to 256M) tips this over the limit, which is what production saw.
2. **File descriptors.** With `worker_processes` sized to 1, the container's 1024 soft
   fd limit capped nginx at ~500 in-flight proxied requests; past that `accept()` failed
   and nginx returned 500 without touching PHP. `auto` had hidden this by running four
   workers. Fixed with `worker_rlimit_nofile 65536` (the hard limit in capsules is
   524288) and `worker_connections 16384`.
3. **Unbounded queueing.** nginx accepted every request and queued it for a worker.
   On a 2-worker capsule a burst left hundreds of doomed requests in the FPM backlog,
   each burning ~60 s of a 0.15-vCPU budget after its client had long gone; PHP-FPM
   was still unresponsive to its own status endpoint eight minutes after the burst
   ended. Fixed with a capsule-wide `limit_conn` sized to `pm.max_children × 8`.
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
| Basic | 0.28 GB | 7% | 128M | 64M | 2 (floor) | 16 | 1 |
| Standard | 0.6 GB | 15% | 128M | 64M | 2 | 16 | 1 |
| Premium | 1 GB | 25% | 128M | 112M | 3 | 24 | 1 |
| Custom | 2 GB | 1 | 256M | 256M | 12 | 96 | 1 |
| Custom | 4 GB | 2 | 256M | 256M | 24 | 192 | 2 |

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

Pending at the time of writing: re-running the hammer with the final image (v4) at
Standard, Premium, Basic and a larger Custom plan.
