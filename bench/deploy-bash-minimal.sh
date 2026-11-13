#!/usr/bin/env bash
# deploy-bash.sh -- bash-only version of the deployer's native_lemp site deploy, for the speed
# comparison with deploy.sh + Ansible (see README.md). Runs ON the target server as root.
#
# It does the same server-side steps as ansible/site.yml for: native_lemp, local environment,
# plain HTTP (no TLS), one site. Not covered: docker_stack, TLS/certbot, production databases,
# setup switches, remote targets, the mongodb extension build.
#
#   deploy-bash.sh --site DOMAIN --repo URL --branch NAME [--key FILE] [--php 8.2]
#                  [--traffic medium] [--db-mode seed|none] [--server-refresh]
set -Eeuo pipefail
umask 022

SITE='' REPO='' BRANCH='main' KEY='' PHP=8.2 TRAFFIC=medium DB_MODE=none REFRESH=0
BASE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
TRAFFIC_JSON="${TRAFFIC_JSON:-$BASE/traffic.json}"
SITES_ROOT=/var/www/html

while (($#)); do
  case $1 in
    --site) SITE=$2; shift 2 ;;
    --repo) REPO=$2; shift 2 ;;
    --branch) BRANCH=$2; shift 2 ;;
    --key) KEY=$2; shift 2 ;;
    --php) PHP=$2; shift 2 ;;
    --traffic) TRAFFIC=$2; shift 2 ;;
    --db-mode) DB_MODE=$2; shift 2 ;;
    --server-refresh) REFRESH=1; shift ;;
    *) echo "unknown option $1" >&2; exit 2 ;;
  esac
done

die()  { echo "error: $*" >&2; exit 1; }
info() { echo "==> $*" >&2; }
[[ $EUID -eq 0 ]] || die "run as root on the target"
[[ -n $SITE && -n $REPO ]] || die "--site and --repo are required"
[[ $DB_MODE =~ ^(seed|none)$ ]] || die "--db-mode seed|none"
[[ -f $TRAFFIC_JSON ]] || die "traffic.json not found ($TRAFFIC_JSON)"

# Phase timing: phase NAME starts a phase; the summary prints at the end
T0=$(date +%s.%N) PH_NAME='' PH_START='' PH_LOG=()
phase() {
  local now; now=$(date +%s.%N)
  [[ -z $PH_NAME ]] || PH_LOG+=("$(printf '%-24s %6.1f s' "$PH_NAME" "$(awk -v a="$now" -v b="$PH_START" 'BEGIN{print a-b}')")")
  PH_NAME=$1 PH_START=$now
  [[ $1 == end ]] || info "$1"
}
finish() {
  local rc=$?
  phase end
  printf '\n---- deploy-bash.sh %s (exit %s) ----\n' "$SITE" "$rc" >&2
  printf '  %s\n' "${PH_LOG[@]}" >&2
  printf '  %-24s %6.1f s\n' TOTAL "$(awk -v a="$(date +%s.%N)" -v b="$T0" 'BEGIN{print a-b}')" >&2
}
trap finish EXIT

# Same names as deploy.sh: compute_linux_user
USER_=$(echo "$SITE" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/_/g')
[[ $USER_ =~ ^[0-9] ]] && USER_="s_$USER_"
if ((${#USER_} > 32)); then USER_="${USER_:0:24}_$(printf '%s' "$SITE" | sha1sum | cut -c1-6)"; fi
DIR="$SITES_ROOT/$SITE"
POOL="/etc/php/$PHP/fpm/pool.d/$SITE.conf"
VHOST="/etc/nginx/sites-available/$SITE.conf"

# ------------------------------------------------------------------ 1. checks
phase checks
. /etc/os-release
[[ $ID == ubuntu && $VERSION_ID =~ ^(22.04|24.04)$ ]] || [[ $ID == debian && $VERSION_ID == 12 ]] || die "unsupported OS $PRETTY_NAME"
marker=$(head -n1 /etc/deployer/setup 2>/dev/null || true)
[[ -z $marker || $marker == native_lemp ]] || die "this server runs $marker"
if getent passwd "$USER_" >/dev/null; then
  getent passwd "$USER_" | cut -d: -f5 | grep -q "deployer-managed-$SITE" || die "user $USER_ exists and is not ours"
fi
listeners=$(ss -ltnp '( sport = :80 or sport = :443 )' 2>/dev/null | tail -n +2)
if [[ -n $listeners ]] && echo "$listeners" | grep -qv '"nginx"'; then die "ports 80/443 used by another process"; fi
for f in /etc/php/*/fpm/pool.d/"$SITE".conf "$VHOST"; do
  [[ ! -f $f ]] || grep -q 'managed by deployer' "$f" || die "$f exists and is not ours"
done
if command -v nginx >/dev/null && ! err=$(nginx -t 2>&1); then
  [[ $err == *"$SITE"* ]] || die "nginx config already broken: $err"
fi

# ------------------------------------------------------------------ 2. server parts (only when missing)
phase server-parts
need_apt=()
[[ -x /usr/sbin/nginx && -f /etc/redis/deployer.conf && $REFRESH == 0 ]] || need_apt+=(nginx redis-server build-essential pkg-config libssl-dev openssl curl git unzip jq)
[[ -x /usr/sbin/php-fpm$PHP && $REFRESH == 0 ]] || need_apt+=(php$PHP-{fpm,cli,mysql,mbstring,xml,curl,zip,gd,bcmath,intl,redis,soap,sqlite3,dev})
[[ -x /usr/sbin/mariadbd && $REFRESH == 0 ]] || need_apt+=(mariadb-server mariadb-client)
if ((${#need_apt[@]})); then
  if ! apt-cache show "php$PHP-fpm" >/dev/null 2>&1; then
    apt-get install -y software-properties-common && add-apt-repository -y ppa:ondrej/php
  fi
  apt-get update -o DPkg::Lock::Timeout=900
  DEBIAN_FRONTEND=noninteractive apt-get install -y -o DPkg::Lock::Timeout=900 "${need_apt[@]}"
fi
if [[ ! -x /usr/local/bin/composer ]]; then
  curl -fsSL -o /usr/local/bin/composer https://getcomposer.org/download/2.7.7/composer.phar
  echo "aab940cd53d285a54c50465820a2080fcb7182a4ba1e5f795abfb10414a4b4be  /usr/local/bin/composer" | sha256sum -c -
  chmod 0755 /usr/local/bin/composer
fi
mkdir -p /etc/deployer
if [[ ! -f /etc/deployer/redis_password ]]; then
  openssl rand -hex 16 > /etc/deployer/redis_password; chmod 0600 /etc/deployer/redis_password
fi
if [[ ! -f /etc/redis/deployer.conf ]]; then
  printf 'requirepass %s\ndatabases 256\n' "$(cat /etc/deployer/redis_password)" > /etc/redis/deployer.conf
  chown redis:redis /etc/redis/deployer.conf; chmod 0640 /etc/redis/deployer.conf
  grep -q '^include /etc/redis/deployer.conf' /etc/redis/redis.conf || echo 'include /etc/redis/deployer.conf' >> /etc/redis/redis.conf
  systemctl restart redis-server
fi

# ------------------------------------------------------------------ 3. services
phase services
systemctl reset-failed nginx "php$PHP-fpm" redis-server 2>/dev/null || true
for s in nginx "php$PHP-fpm" redis-server mariadb; do
  systemctl is-active --quiet "$s" || systemctl start "$s"
  systemctl is-enabled --quiet "$s" || systemctl enable --quiet "$s"
done
REDIS_PASSWORD=$(cat /etc/deployer/redis_password)

# ------------------------------------------------------------------ 4. user and code
phase user-and-code
getent group "$USER_" >/dev/null || groupadd "$USER_"
getent passwd "$USER_" >/dev/null || useradd -g "$USER_" -d "$DIR" -M -s /usr/sbin/nologin -c "deployer-managed-$SITE" "$USER_"
UID_=$(id -u "$USER_") GID_=$(id -g "$USER_")
install -d -m 0755 -o root -g root "$SITES_ROOT"
install -d -m 0755 -o "$UID_" -g "$GID_" "$DIR"
export GIT_SSH_COMMAND="ssh -o StrictHostKeyChecking=accept-new${KEY:+ -i $KEY -o IdentitiesOnly=yes}"
export GIT_CONFIG_COUNT=2 GIT_CONFIG_KEY_0=safe.directory GIT_CONFIG_VALUE_0='*' GIT_CONFIG_KEY_1=core.fileMode GIT_CONFIG_VALUE_1=false
if [[ -d $DIR/.git ]]; then
  git -C "$DIR" fetch --quiet origin "$BRANCH"
  git -C "$DIR" reset --quiet --hard FETCH_HEAD
else
  git clone --quiet --branch "$BRANCH" "$REPO" "$DIR.tmp"
  shopt -s dotglob; mv "$DIR.tmp"/* "$DIR"/; shopt -u dotglob; rmdir "$DIR.tmp"
fi
install -d -m 0775 -o "$UID_" -g "$GID_" "$DIR/storage" "$DIR/bootstrap/cache"
chown -R "$UID_:$GID_" "$DIR"
chmod -R a+rX "$DIR"
chmod -R 0775 "$DIR/storage" "$DIR/bootstrap/cache"

# ------------------------------------------------------------------ 5. redis databases
phase redis-db
REG=/etc/deployer/redis-dbs; touch "$REG"
if line=$(grep -E "^[0-9]+[[:space:]]+[0-9]+[[:space:]]+$SITE\$" "$REG"); then
  read -r RDB RCACHE _ <<< "$line"
else
  max=$(awk '{for (i = 1; i <= NF; i++) if ($i ~ /^[0-9]+$/) print $i}' "$REG" | sort -n | tail -1)
  next=$(( ${max:--1} + 1 )); next=$(( next + next % 2 ))
  RDB=$next RCACHE=$((next + 1))
  ((RCACHE < 256)) || die "no free Redis database"
  echo "$RDB $RCACHE $SITE" >> "$REG"
fi

# ------------------------------------------------------------------ 6. .env
phase env
ENV="$DIR/.env"
if [[ ! -f $ENV ]]; then
  if [[ -f $DIR/.env.example ]]; then cp "$DIR/.env.example" "$ENV"; else : > "$ENV"; fi
fi
chown "$USER_:$USER_" "$ENV"; chmod 0600 "$ENV"
sed -i -E 's/^([ \t]*[^=#]*\(.*\)[^=]*=.*)$/# \1/' "$ENV"
grep -qE '^APP_KEY=.+' "$ENV" || set_key=1
if [[ ! -f /etc/deployer/db_pass_$USER_ ]]; then
  echo "DB_PASSWORD=$(openssl rand -hex 16)" > "/etc/deployer/db_pass_$USER_"; chmod 0600 "/etc/deployer/db_pass_$USER_"
fi
DB_PASS=$(grep ^DB_PASSWORD= "/etc/deployer/db_pass_$USER_" | cut -d= -f2)
# env_set KEY VALUE: replaces KEY=... or appends it, value quoted like the playbook does
env_set() {
  local v=${2//\\/\\\\}; v=${v//\"/\\\"}; v=${v//\$/\\\$}
  local line="$1=\"$v\"" tmp; tmp=$(mktemp)
  awk -v k="$1" -v l="$line" 'BEGIN{d=0} $0 ~ "^"k"=" {if(!d){print l; d=1}; next} {print} END{if(!d) print l}' "$ENV" > "$tmp"
  cat "$tmp" > "$ENV"; rm -f "$tmp"
}
[[ -z ${set_key:-} ]] || env_set APP_KEY "base64:$(openssl rand -base64 32)"
env_set APP_ENV local; env_set APP_DEBUG true; env_set APP_URL "http://$SITE"
env_set DB_CONNECTION mysql; env_set DB_HOST 127.0.0.1; env_set DB_PORT 3306
env_set DB_DATABASE "$USER_"; env_set DB_USERNAME "$USER_"; env_set DB_PASSWORD "$DB_PASS"
env_set REDIS_HOST 127.0.0.1; env_set REDIS_PASSWORD "$REDIS_PASSWORD"
env_set REDIS_DB "$RDB"; env_set REDIS_CACHE_DB "$RCACHE"; env_set REDIS_PREFIX "${USER_}_"

# ------------------------------------------------------------------ 7. PHP-FPM pool and nginx vhost (rolled back when rejected)
phase pool-and-vhost
tj() { jq -r --arg t "$TRAFFIC" ".[\$t].$1 // empty" "$TRAFFIC_JSON"; }
pm=$(tj pm)
{
  echo "; managed by deployer"
  echo "; PHP-FPM pool for $SITE (traffic: $TRAFFIC)"
  echo "[$SITE]"
  echo "user = $USER_"; echo "group = $USER_"
  echo "listen = /run/php/php$PHP-fpm-$SITE.sock"
  echo "listen.owner = www-data"; echo "listen.group = www-data"; echo "listen.mode = 0660"; echo
  echo "pm = $pm"; echo "pm.max_children = $(tj max_children)"
  if [[ $pm == ondemand ]]; then [[ -z $(tj idle_timeout) ]] || echo "pm.process_idle_timeout = $(tj idle_timeout)"
  else echo "pm.start_servers = $(tj start_servers)"; echo "pm.min_spare_servers = $(tj min_spare)"; echo "pm.max_spare_servers = $(tj max_spare)"; fi
  [[ -z $(tj max_requests) ]] || echo "pm.max_requests = $(tj max_requests)"
  echo; echo "clear_env = no"; echo "catch_workers_output = yes"
} > "$POOL.new"
if ! cmp -s "$POOL.new" "$POOL"; then
  [[ ! -f $POOL ]] || cp -p "$POOL" "$POOL.bak"
  mv "$POOL.new" "$POOL"
  if ! php-fpm"$PHP" -t 2>/dev/null || ! systemctl reload "php$PHP-fpm"; then
    if [[ -f $POOL.bak ]]; then mv "$POOL.bak" "$POOL"; else rm -f "$POOL"; fi
    systemctl reload "php$PHP-fpm" || true
    die "PHP-FPM rejected the new pool; previous one restored"
  fi
  rm -f "$POOL.bak"
else
  rm -f "$POOL.new"
fi
for f in /etc/nginx/sites-enabled/*; do
  [[ -e $f && $(basename "$f") != "$SITE.conf" ]] || continue
  if grep -Eq "^[[:space:]]*server_name[[:space:]]+([^;]*[[:space:]])?${SITE//./\\.}([[:space:]]|;)" "$f"; then die "server_name $SITE already used in $f"; fi
done
cat > "$VHOST.new" <<EOF
# managed by deployer
# Server block for $SITE (native_lemp, traffic: $TRAFFIC). Re-rendered on every deploy.
server {
    listen 80;
    server_name $SITE;

    root $SITES_ROOT/$SITE/public;
    index index.php;
    access_log /var/log/nginx/$SITE.access.log;
    error_log /var/log/nginx/$SITE.error.log;

    add_header X-Content-Type-Options "nosniff" always;
    add_header X-Frame-Options "SAMEORIGIN" always;

    location ~ /\.(?!well-known) { deny all; }

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \.php\$ {
        try_files \$uri =404;
        include fastcgi_params;
        fastcgi_pass unix:/run/php/php$PHP-fpm-$SITE.sock;
        fastcgi_param SCRIPT_FILENAME \$realpath_root\$fastcgi_script_name;
        fastcgi_read_timeout 60s;
    }
}
EOF
had_link=0; [[ -L /etc/nginx/sites-enabled/$SITE.conf ]] && had_link=1
[[ ! -f $VHOST ]] || cp -p "$VHOST" "$VHOST.bak"
mv "$VHOST.new" "$VHOST"
ln -sfn "$VHOST" "/etc/nginx/sites-enabled/$SITE.conf"
if ! nginx -t 2>/dev/null || ! systemctl reload nginx; then
  rm -f "/etc/nginx/sites-enabled/$SITE.conf"
  if [[ -f $VHOST.bak ]]; then mv "$VHOST.bak" "$VHOST"; else rm -f "$VHOST"; fi
  if ((had_link)) && [[ -f $VHOST ]]; then ln -s "$VHOST" "/etc/nginx/sites-enabled/$SITE.conf"; fi
  nginx -t 2>/dev/null && systemctl reload nginx || true
  die "nginx rejected the new vhost; previous one restored"
fi
rm -f "$VHOST.bak"
for f in /etc/php/*/fpm/pool.d/"$SITE".conf; do
  v=$(echo "$f" | cut -d/ -f4)
  if [[ -f $f && $v != "$PHP" ]] && head -n1 "$f" | grep -q 'managed by deployer'; then rm -f "$f"; systemctl reload "php$v-fpm" || true; fi
done

# ------------------------------------------------------------------ 8. database
phase database
for i in $(seq 20); do mariadb -N -e 'SELECT 1' >/dev/null 2>&1 && break; sleep 2; done
mariadb <<SQL
CREATE DATABASE IF NOT EXISTS \`$USER_\`;
CREATE USER IF NOT EXISTS '$USER_'@'%' IDENTIFIED BY '$DB_PASS';
ALTER USER '$USER_'@'%' IDENTIFIED BY '$DB_PASS';
CREATE USER IF NOT EXISTS '$USER_'@'localhost' IDENTIFIED BY '$DB_PASS';
ALTER USER '$USER_'@'localhost' IDENTIFIED BY '$DB_PASS';
GRANT ALL ON \`$USER_\`.* TO '$USER_'@'%', '$USER_'@'localhost'; FLUSH PRIVILEGES;
SQL
TABLES=0
[[ $DB_MODE != seed ]] || TABLES=$(mariadb -N -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = '$USER_'")

# ------------------------------------------------------------------ 9. Laravel
phase composer
PHP_EXEC=(sudo -u "$USER_" "/usr/bin/php$PHP")
git -C "$DIR" ls-files --error-unmatch composer.lock >/dev/null 2>&1 || rm -f "$DIR/composer.lock"
(cd "$DIR" && sudo -u "$USER_" env COMPOSER_NO_BLOCKING=1 COMPOSER_NO_AUDIT=1 "/usr/bin/php$PHP" /usr/local/bin/composer install --optimize-autoloader --no-interaction -q)
phase artisan
cd "$DIR"
if [[ -f artisan ]]; then
  [[ -e public/storage || -L public/storage ]] || "${PHP_EXEC[@]}" artisan storage:link -q
  if [[ $DB_MODE == seed && $TABLES == 0 ]]; then "${PHP_EXEC[@]}" artisan migrate -q; fi
  [[ $DB_MODE != seed ]] || "${PHP_EXEC[@]}" artisan db:seed -q
  sed -i "\| # deployer:$SITE\$|d" /etc/cron.d/laravel-schedulers 2>/dev/null || true
fi

# ------------------------------------------------------------------ 10. verify and record
phase verify
code=''
for i in $(seq 10); do
  code=$(curl -s -o /dev/null -w '%{http_code}' -H "Host: $SITE" http://127.0.0.1/ || true)
  [[ $code =~ ^(200|301|302|401)$ ]] && break
  sleep 3
done
[[ $code =~ ^(200|301|302|401)$ ]] || die "site answered HTTP $code: $(tail -n 30 /var/log/nginx/$SITE.error.log 2>/dev/null)"
mkdir -p /etc/deployer/sites
printf '{"domain":"%s","aliases":[],"linux_user":"%s","project_folder":"%s","setup":"native_lemp","php_version":"%s","traffic":"%s","tls_mode":"none","environment":"local","redis_db_session":%s,"redis_db_cache":%s,"last_deploy":"%s","status":"active"}\n' \
  "$SITE" "$USER_" "$DIR" "$PHP" "$TRAFFIC" "$RDB" "$RCACHE" "$(date +%F)" > "/etc/deployer/sites/$SITE.json"
chmod 0644 "/etc/deployer/sites/$SITE.json"
[[ -n $marker ]] || echo native_lemp > /etc/deployer/setup
info "Done: $SITE answered HTTP $code"
