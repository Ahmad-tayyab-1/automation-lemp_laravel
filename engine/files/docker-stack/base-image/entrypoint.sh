#!/bin/sh
# Creates the site's Linux user inside the container at start time, so one shared
# image can serve every site. The UID/GID must match the host owner of the project
# folder, otherwise PHP cannot write to storage/ (a bind mount compares numbers,
# not names).
#
# Required env (set in the site's docker-compose.yml):
#   APP_USER  e.g. textoinvisible_info
#   APP_UID   e.g. 1001
#   APP_GID   e.g. 1001
set -e

# Ad-hoc runs don't need a site user, e.g.  docker run --rm <image> php -m
if [ -z "${APP_USER:-}" ] && [ "${1:-}" != "php-fpm" ]; then
    exec docker-php-entrypoint "$@"
fi

: "${APP_USER:?APP_USER env var is required (site Linux user name)}"
: "${APP_UID:?APP_UID env var is required (must match host owner UID)}"
: "${APP_GID:?APP_GID env var is required (must match host owner GID)}"

# Group: reuse whatever already owns this GID, otherwise create it.
if getent group "$APP_GID" >/dev/null 2>&1; then
    APP_GROUP="$(getent group "$APP_GID" | cut -d: -f1)"
else
    addgroup -g "$APP_GID" "$APP_USER"
    APP_GROUP="$APP_USER"
fi

# User: the UID is what matters; the name is for convenience
# (docker compose exec -u <name>, $HOME for the SSH deploy key, composer cache).
if getent passwd "$APP_UID" >/dev/null 2>&1; then
    APP_USER="$(getent passwd "$APP_UID" | cut -d: -f1)"
else
    adduser -D -u "$APP_UID" -G "$APP_GROUP" -h "/home/$APP_USER" -s /bin/bash "$APP_USER"
fi

# www-data (33) membership: lets the site user work with group-owned project files.
adduser "$APP_USER" www-data 2>/dev/null || true

# Home directory. Docker may already have created it while mounting the read-only
# .ssh folder, in which case it belongs to root. Fix the top level only, never
# recurse into the mount.
mkdir -p "/home/$APP_USER" 2>/dev/null || true
chown "$APP_UID:$APP_GID" "/home/$APP_USER" 2>/dev/null || true

# Hand over to the base image's own entrypoint so php / php-fpm behave normally.
exec docker-php-entrypoint "$@"
