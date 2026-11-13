#!/usr/bin/env bash
# site-docker.sh — generates this site's docker-compose.yml and php/ config files.
#
# Copy this script into a project folder and run it FROM that folder. It works out
# the project path, the owning Linux user and that user's UID/GID by itself, and
# writes files that match. Run it again any time (after chown, after moving the
# project): it re-detects, shows what changed, and keeps a .bak of anything it
# overwrites.
#
# It does NOT build or start anything — it prints the commands to run at the end.
#
#   ./site-docker.sh          generate / update
#   ./site-docker.sh --check  show what it detected and what would change, write nothing
set -euo pipefail

BASE_IMAGE="${BASE_IMAGE:-enzipe/php-fpm:8.2-alpine}"
SOCKET_DIR="/run/php-docker"
MEM_LIMIT="${MEM_LIMIT:-1g}"
CPUS="${CPUS:-2}"
SLOWLOG_SECONDS="${SLOWLOG_SECONDS:-3}"
PM_MAX_CHILDREN="${PM_MAX_CHILDREN:-5}"

DRY_RUN=0
[ "${1:-}" = "--check" ] && DRY_RUN=1

say()  { printf '  %s\n' "$*"; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$*"; }
die()  { printf '\n  \033[31m✗ %s\033[0m\n\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- detect

APP_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ -f "$APP_PATH/artisan" ] || warn "no artisan file here — is $APP_PATH really the project root?"

APP_USER="$(stat -c %U "$APP_PATH")"
APP_UID="$(stat -c %u "$APP_PATH")"
# The user's OWN primary group, not the folder's group (the folder's group is
# normally www-data, which the user is a member of but must not be created with).
APP_GID="$(id -g "$APP_USER" 2>/dev/null || stat -c %g "$APP_PATH")"
DIR_GROUP="$(stat -c %G "$APP_PATH")"
[ "$APP_USER" = "UNKNOWN" ] && die "the folder's owner UID ($APP_UID) has no user on this host — fix ownership first"

# Do tareeqe support hain:
#   dedicated -> folder ka owner ek asli site user hai; pool usi user se chalta hai.
#                Behtar isolation: ek site doosri site ki files nahi chhoo sakti.
#   shared    -> folder root ki hai (ya site user bana hi nahi); pool www-data se
#                chalta hai aur group ke zariye likhta hai. PHP-FPM root se chalta
#                hi nahi ("please specify user and group other than root"), is liye
#                root wale projects ke liye yehi aik rasta hai.
POOL_MODE="dedicated"
if [ "$APP_USER" = "root" ]; then
    POOL_MODE="shared"
    APP_USER="www-data"
    APP_UID="$(id -u www-data)"
    APP_GID="$(id -g www-data)"
fi

# The site's own group may be the user's group; the shared group with nginx is www-data.
WWW_GID="$(id -g www-data 2>/dev/null || echo "")"
[ -n "$WWW_GID" ] || die "no www-data user on this host — nginx shares that group with the FPM socket"
[ "$WWW_GID" = "33" ] || warn "www-data gid is $WWW_GID, not the expected 33 — the base image creates 33"
[ "$DIR_GROUP" = "www-data" ] || warn "project folder group is $DIR_GROUP, not www-data — nginx reads files through that group:
      chown -R $APP_USER:www-data $APP_PATH"

# Naam kis se banein:
#   dedicated -> site ke user se (yehi vhost ke socket path mein pehle se likha hai)
#   shared    -> user sab ka ek hi (www-data) hota hai, is liye FOLDER ke naam se,
#                warna do root-wale projects ka socket/container aapas mein takra jayein
if [ "$POOL_MODE" = "shared" ]; then
    NAME_BASE="$(basename "$APP_PATH")"
else
    NAME_BASE="$APP_USER"
fi
SOCKET_NAME="$(printf '%s' "$NAME_BASE" | tr '.-' '__')"
POOL_NAME="$SOCKET_NAME"
CONTAINER_NAME="$(printf '%s' "$NAME_BASE" | tr '._' '--')-php"
SSH_DIR="$(getent passwd "$APP_USER" | cut -d: -f6)"

printf '\n  Detected\n'
say "project path   : $APP_PATH"
say "site user      : $APP_USER (uid $APP_UID, gid $APP_GID)"
say "folder group   : $DIR_GROUP"
if [ "$POOL_MODE" = "shared" ]; then
    say "pool mode      : shared  (folder root ki hai -> PHP www-data se chalegi)"
else
    say "pool mode      : dedicated  (pool site ke apne user se chalega)"
fi
say "www-data gid   : $WWW_GID"
say "container name : $CONTAINER_NAME"
say "fpm socket     : $SOCKET_DIR/$SOCKET_NAME.sock"
say "base image     : $BASE_IMAGE"
say "ssh key dir    : ${SSH_DIR:-none}"

# Warn if the vhost expects a different socket name than we are about to create.
VHOST_SOCK="$(grep -RhoE "$SOCKET_DIR/[A-Za-z0-9_.-]+\.sock" /etc/nginx/sites-enabled/ 2>/dev/null \
              | sort -u | grep -F "$SOCKET_NAME.sock" || true)"
if [ -z "$VHOST_SOCK" ]; then
    warn "no enabled vhost points at $SOCKET_DIR/$SOCKET_NAME.sock — check the site's nginx vhost"
else
    ok "vhost already points at this socket"
fi

if [ "$DRY_RUN" = "1" ]; then
    printf '\n  --check: nothing written.\n\n'
    exit 0
fi

# ---------------------------------------------------------------- write

backup() { [ -f "$1" ] && cp -p "$1" "$1.bak.$(date +%Y%m%d-%H%M%S)" && say "backup: $(basename "$1").bak.*"; return 0; }

mkdir -p "$APP_PATH/php"

printf '\n  Writing\n'

# ---- docker-compose.yml
backup "$APP_PATH/docker-compose.yml"
cat > "$APP_PATH/docker-compose.yml" <<YAML
# Generated by site-docker.sh — re-run that script instead of hand-editing the
# identity values (user, uid, gid, paths). Tuning values below are safe to edit.
services:
  php:
    # Shared base image, built once for all sites. No per-site build here.
    image: $BASE_IMAGE
    container_name: $CONTAINER_NAME
    restart: always

    # Host network: 127.0.0.1 inside the container is the host, so the site's
    # REDIS_HOST / DB_HOST settings work unchanged.
    network_mode: host

    working_dir: $APP_PATH

    # The base image creates this user at start-up, so one image fits every site.
    environment:
      APP_USER: $APP_USER
      APP_UID: "$APP_UID"
      APP_GID: "$APP_GID"

    volumes:
      # Project code and .env — same path inside and outside
      - $APP_PATH:$APP_PATH
      # FPM socket folder shared with the nginx container
      - $SOCKET_DIR:$SOCKET_DIR
      # Redis unix socket (sites that connect over the socket instead of TCP)
      - /run/redis:/run/redis
      # Site PHP settings on top of the image's php.ini-production (conf.d, loaded last);
      # host par edit karein, phir reload: docker compose kill -s SIGUSR2 php
      - ./php/php.ini:/usr/local/etc/php/conf.d/zz-site.ini:ro
      - ./php/pool.conf:/usr/local/etc/php-fpm.d/zz-app.conf:ro
      - ./php/docker.conf:/usr/local/etc/php-fpm.d/docker.conf:ro
$( [ -n "$SSH_DIR" ] && [ -d "$SSH_DIR/.ssh" ] && printf '      # Deploy key for git pull inside the container (read-only)\n      - %s/.ssh:%s/.ssh:ro' "$SSH_DIR" "$SSH_DIR" )

    # Asks PHP-FPM itself over its socket — catches "container up but FPM wedged".
    healthcheck:
      test: ["CMD-SHELL", "SCRIPT_NAME=/ping SCRIPT_FILENAME=/ping REQUEST_METHOD=GET cgi-fcgi -bind -connect $SOCKET_DIR/$SOCKET_NAME.sock 2>/dev/null | grep -q pong"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 15s

    mem_limit: $MEM_LIMIT
    cpus: $CPUS

    logging:
      driver: json-file
      options:
        max-size: "20m"
        max-file: "5"

# One-off commands (run manually when needed):
#   docker compose exec -u $APP_USER php composer install --no-dev -o
#   docker compose exec -u $APP_USER php php artisan migrate --force
#   docker compose exec -u $APP_USER php php artisan optimize:clear
YAML
ok "docker-compose.yml"

# ---- php/pool.conf
backup "$APP_PATH/php/pool.conf"
cat > "$APP_PATH/php/pool.conf" <<POOL
; Generated by site-docker.sh. Identity lines (pool name, user, group, listen)
; are rewritten by the script; the tuning below is yours to change — edit and
; reload with:  docker compose kill -s SIGUSR2 php
[$POOL_NAME]
user = $APP_USER
group = $APP_USER

listen = $SOCKET_DIR/$SOCKET_NAME.sock
listen.owner = www-data
listen.group = www-data
listen.mode = 0660

pm = dynamic
pm.max_children = $PM_MAX_CHILDREN
pm.start_servers = 2
pm.min_spare_servers = 1
pm.max_spare_servers = 3

catch_workers_output = yes
clear_env = no

; Used by the container healthcheck in docker-compose.yml
ping.path = /ping
ping.response = pong

; Requests slower than ${SLOWLOG_SECONDS}s are logged with a full stack trace.
; storage/logs is inside the project, so the file is readable on the host.
slowlog = $APP_PATH/storage/logs/php-fpm-slow.log
request_slowlog_timeout = ${SLOWLOG_SECONDS}s
POOL
ok "php/pool.conf  (slowlog ${SLOWLOG_SECONDS}s, ping.path /ping)"

# ---- php/docker.conf  (only if missing — it is identical for every site)
if [ ! -f "$APP_PATH/php/docker.conf" ]; then
cat > "$APP_PATH/php/docker.conf" <<'GLOBAL'
; PHP-FPM global settings. Replaces the base image's docker.conf / zz-docker.conf.
;   error_log : errors go to "docker compose logs php"
;   daemonize : must be "no", otherwise FPM backgrounds itself and the container exits
[global]
error_log = /proc/self/fd/2
log_limit = 8192
daemonize = no
GLOBAL
ok "php/docker.conf"
else
    say "php/docker.conf already present, left alone"
fi

# ---- php/php.ini  (site settings on top of php.ini-production; sirf tab aati hai jab maujood na ho)
if [ ! -f "$APP_PATH/php/php.ini" ]; then
    if [ -f /opt/docker-stack/php/site-php.ini ]; then
        cp /opt/docker-stack/php/site-php.ini "$APP_PATH/php/php.ini"
        ok "php/php.ini  (site settings, mounted as conf.d/zz-site.ini)"
    else
        warn "/opt/docker-stack/php/site-php.ini nahi mili — php.ini copy nahi hui"
    fi
else
    say "php/php.ini already present, left alone"
fi

# ---- writable dirs the app and FPM need
mkdir -p "$APP_PATH/storage/logs" "$APP_PATH/bootstrap/cache"
if [ "$POOL_MODE" = "shared" ]; then
    # PHP ab malik nahi, sirf www-data group se likhegi -> group-write lazmi hai,
    # aur setgid taake nayi files bhi www-data group ki banein.
    chgrp -R www-data "$APP_PATH/storage" "$APP_PATH/bootstrap/cache" 2>/dev/null || true
    chmod -R g+w      "$APP_PATH/storage" "$APP_PATH/bootstrap/cache" 2>/dev/null || true
    find "$APP_PATH/storage" "$APP_PATH/bootstrap/cache" -type d -exec chmod g+s {} + 2>/dev/null || true
    ok "storage + bootstrap/cache www-data group ke liye likhne layak (shared mode)"
else
    chown "$APP_UID:$WWW_GID" "$APP_PATH/php" "$APP_PATH/docker-compose.yml" 2>/dev/null || true
    chown -R "$APP_UID:$WWW_GID" "$APP_PATH/storage/logs" 2>/dev/null || true
    ok "storage/logs ready, files owned by $APP_USER:www-data"
fi

# ---------------------------------------------------------------- validate

printf '\n  Validating\n'
if docker compose -f "$APP_PATH/docker-compose.yml" config -q 2>/dev/null; then
    ok "docker compose config is valid"
else
    warn "docker compose config failed — run it yourself to see why:"
    say  "  cd $APP_PATH && docker compose config"
fi

if ! docker image inspect "$BASE_IMAGE" >/dev/null 2>&1; then
    warn "base image $BASE_IMAGE is not built yet on this host"
fi

# ---------------------------------------------------------------- next steps

cat <<NEXT

  Next, run these yourself:

    cd $APP_PATH
    docker compose up -d
    docker compose ps
    docker compose logs --tail 20 php
    ls -l $SOCKET_DIR/$SOCKET_NAME.sock

  Inside the container (as the site user):

    docker compose exec -u $APP_USER php bash

  Laravel scheduler cron line for this site (add to /etc/cron.d/laravel-schedulers):

    * * * * * root /usr/bin/docker exec -u $APP_USER $CONTAINER_NAME php artisan schedule:run >/dev/null 2>&1

NEXT
