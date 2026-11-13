#!/usr/bin/env bash
# cleanup-site.sh DOMAIN: removes a test site completely (files, user, database, Redis databases, pool or
# PHP container, vhost, records). native_lemp and docker_stack. Only for test sites named bench-*.test.
set -uo pipefail
D=$1
case $D in bench-*.test) ;; *) echo "refusing: only bench-*.test sites" >&2; exit 1 ;; esac
U=$(echo "$D" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/_/g')
SETUP=$(head -n 1 /etc/deployer/setup 2>/dev/null)
if [ "$SETUP" = docker_stack ]; then
  P=$(sed -n 's/^requirepass \([^ ]*\).*/\1/p' /opt/docker-stack/redis/redis.conf | head -n 1)
  rcli() { docker exec -e REDISCLI_AUTH="$P" enzipe-redis redis-cli "$@"; }
  dbq() { docker exec -i -e MYSQL_PWD="$(sed -n 's/^DB_ROOT_PASSWORD=//p' /opt/docker-stack/.env)" enzipe-mariadb mariadb -uroot "$@"; }
else
  P=$(cat /etc/deployer/redis_password 2>/dev/null)
  rcli() { REDISCLI_AUTH=$P redis-cli "$@"; }
  dbq() { mariadb "$@"; }
fi
for n in $(awk -v d="$D" '$3 == d {print $1, $2}' /etc/deployer/redis-dbs 2>/dev/null); do
  rcli -n "$n" FLUSHDB >/dev/null 2>&1
done
awk -v d="$D" '$3 != d' /etc/deployer/redis-dbs > /tmp/rdbs.$$ && cat /tmp/rdbs.$$ > /etc/deployer/redis-dbs; rm -f /tmp/rdbs.$$
if [ "$SETUP" = docker_stack ]; then
  [ -f "/var/www/html/$D/docker-compose.yml" ] && (cd -P "/var/www/html/$D" && docker compose down --remove-orphans >/dev/null 2>&1)
  rm -f /opt/docker-stack/nginx/conf/sites-enabled/"$D" /opt/docker-stack/nginx/conf/sites-available/"$D" /opt/docker-stack/nginx/conf/sites-available/"$D".*~
  docker exec enzipe-nginx nginx -t -q && docker exec enzipe-nginx nginx -s reload
  rm -f /run/php-docker/"$U".sock
else
  rm -f /etc/php/*/fpm/pool.d/"$D".conf* /etc/nginx/sites-enabled/"$D".conf /etc/nginx/sites-available/"$D".conf*
  systemctl reload php8.2-fpm nginx
fi
echo "DROP DATABASE IF EXISTS \`$U\`; DROP USER IF EXISTS '$U'@'%'; DROP USER IF EXISTS '$U'@'localhost';" | dbq
rm -rf "/etc/deployer/db_pass_$U" "/etc/deployer/sites/$D.json" /var/log/nginx/"$D".* "/etc/ssl/deployer/$D"
[ -f /etc/cron.d/laravel-schedulers ] && sed -i "\\| # deployer:$D\$|d" /etc/cron.d/laravel-schedulers
pkill -u "$U" 2>/dev/null; sleep 1
userdel "$U" 2>/dev/null; groupdel "$U" 2>/dev/null
rm -rf "/var/www/html/$D"
echo "removed $D"
