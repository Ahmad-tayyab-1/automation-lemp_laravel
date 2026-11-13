# docker-stack in the deployer: differences from the stack zip

The docker-stack zip is the `/opt/docker-stack` setup described in `SETUP.md`. In the deployer it
lives in two places. When a new zip arrives, copy its files over these and re-apply the changes below.

## Where the files go

| In the deployer | On the server | Rule |
|---|---|---|
| `ansible/files/docker-stack/` | `/opt/docker-stack/` | Copied on every deploy (Dockerfiles, scripts, watchdog units, stock nginx includes) |
| `ansible/templates/docker-stack-nginx.conf.j2` | `nginx/conf/nginx.conf` | Written **only when missing**: edit it on the server |
| `ansible/templates/docker-stack-redis.conf.j2` | `redis/redis.conf` | Written only when missing, with a generated password |
| `ansible/templates/docker-stack-watchdog.conf.j2` | `watchdog/watchdog.conf` (0600) | Written only when missing; the webhook is set by `deploy.sh` |
| (created empty) | `nginx/conf/snippets/blockips.conf` | Created only when missing |
| `ansible/templates/docker-stack-compose.yml.j2` | `docker-compose.yml` | Rendered on every deploy |
| `ansible/templates/docker-stack-db-compose.yml.j2` | `db/docker-compose.yml` | Rendered on every deploy (local MariaDB, new) |
| `ansible/templates/docker-stack-admin-ips.conf.j2`, `…-whitelist-ips.conf.j2` | `nginx/conf/snippets/` | First install and `--stack-config` |
| `ansible/templates/docker-site-compose.yml.j2`, `docker-site-pool.conf.j2`, `files/docker-site-fpm-global.conf` | `<project>/docker-compose.yml`, `<project>/php/` | Per site, the same files `site-docker.sh` writes |
| `files/docker-stack/php/site-php.ini` | `<project>/php/php.ini` | Per site, copied only when missing |
| `ansible/templates/site-vhost.conf.j2` | `nginx/conf/sites-available/<domain>` (+ relative symlink in `sites-enabled/`) | Per site (shared with native_lemp) |

## Changes against the zip

1. **Secrets removed.** The values are asked or generated per server and never stored in the repo:
   - **Redis password:** generated per server into `redis.conf`.
   - **Discord webhook:** asked by `deploy.sh` (hidden input, or `DEPLOY_DISCORD_WEBHOOK`) and written only on the server. Without a webhook the watchdog units are not installed.
   - **Certificates:** the zip's certificates and private keys (`nginx/conf/cert/*`) are not shipped. Certificates come from the deployer's TLS options, in `/etc/nginx/cert/<domain>/` (`certificate.crt`, `privatekey.key`).
2. **Server-specific files not shipped:**
   - the vhosts in `sites-available`/`sites-enabled` (`textoinvisible.info`, `dozzle`); the deployer writes site vhosts itself
   - `conf.d/php_status.conf`, which points to a staging-only socket
   - unused stock files: `rate-limiting.conf` (it also refers to rate-limit zones that do not exist), `snakeoil.conf`, `scgi_params`, `uwsgi_params`, `proxy_params`
3. **`redis.conf`** keeps exactly the zip's 76 active settings (same values, same order). The 2,000 lines of stock comments are dropped. `requirepass` is generated per server.
4. **`php.ini`**:
   - The zip copied a full 2,000-line `php.ini` into every project and mounted it over the image's `php.ini`. Only 10 settings in it differ from PHP's own `php.ini-production`, which the image already uses.
   - Each site now gets `php/php.ini` with just those settings (`php/site-php.ini`: opcache, `expose_php`, `error_log`). It is mounted as `/usr/local/etc/php/conf.d/zz-site.ini`, so it applies on top of `php.ini-production`. The effective settings are the same.
   - An existing full `php/php.ini` also works in that place.
   - `site-docker.sh` was changed the same way (mount and copy source).
5. **`docker-compose.yml`**:
   - redis `user:` is the server's `redis` uid:gid. The user is created if missing, instead of the hardcoded `110:113`.
   - nginx also mounts `/etc/nginx/cert:/etc/nginx/cert:ro`, and `/etc/ssl/deployer` for sites not deployed since the certificates moved.
6. **`nginx.conf`**: the IPs in `geo $whitelist` moved to `snippets/whitelist_ips.conf` (asked by `deploy.sh`). `snippets/allowed_admin_ips.conf` is also asked:
   - It is included at http level, so it is a **staging lock for every site**.
   - `none` makes the sites public.
   - `127.0.0.1` and `::1` are always allowed, for the deploy health check.
   - The vhost's ACME location has `allow all`, so certbot works behind the lock.
7. **Host setup from `SETUP.md`** is done by the playbook (folders, owners, `/etc/tmpfiles.d/php-docker.conf`). In addition, `/etc/tmpfiles.d/docker-stack-redis.conf` recreates `/run/redis` after a reboot.
8. **Local MariaDB** (`db/docker-compose.yml`, container `enzipe-mariadb`) is new:
   - host network, bound to `127.0.0.1:3306`
   - root password in `/opt/docker-stack/.env` (0600), data in `/opt/docker-stack/db/data`
   - only started for `--env local` deploys
9. **Pool tuning** (`pm.*`) comes from the deployer's `traffic.json` level instead of `site-docker.sh`'s fixed values. `mem_limit`/`cpus` default to the zip's `1g`/`2` and can be set per traffic level.
10. **`check-docker.sh`** runs before the images are built. A failed required check stops the deploy.
11. **`base-image/Dockerfile`** adds the PECL **mongodb** extension, pinned to `1.20.1` (`ARG MONGODB_VERSION`), with `openssl-dev` in the builder stage. Projects on `mongodb/mongodb` 1.x need `ext-mongodb ^1.x` (e.g. standardformcalculator.com).
12. **Scheduler**: the cron line `site-docker.sh` prints is added by the deployer to `/etc/cron.d/laravel-schedulers`, tagged `# deployer:<domain>`. Manual lines in that file are left alone.
    - It is on for production and off for local, unless `"scheduler"` is set in `sites.json`.
    - A "close" switch removes the deployer-tagged lines.
13. **vhost**:
    - the "deny dot-files" location comes first, so it is matched before the PHP and static-file locations
    - `http2 on;` replaces the deprecated `listen … http2`
