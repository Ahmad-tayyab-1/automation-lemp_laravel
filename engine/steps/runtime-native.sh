# steps/runtime-native.sh - every native_lemp deploy: the services are running, and the site steps get
# the Redis password and the PHP, Composer and database (MariaDB or MySQL) commands.

section "Native runtime"

# The local database server: MySQL when the server runs MySQL (deploy.sh server), else MariaDB
db_service=mariadb db_client=mariadb
if [[ -x /usr/sbin/mysqld && ! -x /usr/sbin/mariadbd ]]; then db_service=mysql db_client=mysql; fi

# The services are enabled and started (a previous failed state is cleared first, so systemd's start
# limit cannot block them), and the Redis password is read.
task "Start nginx, php-fpm, redis-server (and the database server for local sites) and read the Redis password" secret
f=/etc/deployer/redis_password
if [[ ! -f $f ]]; then
  dry || fail "$f is missing. Deploy again with --server-refresh to set Redis up again."
  redis_password=''
else
  if ! dry; then
    services="nginx php$php_version-fpm redis-server"; [[ $deploy_env != local ]] || services+=" $db_service"
    systemctl reset-failed $services 2>/dev/null || true
    for s in $services; do
      systemctl is-enabled --quiet "$s" || { systemctl enable --quiet "$s"; changed; }
      systemctl is-active --quiet "$s" || systemctl start "$s" \
        || fail "Could not start $s: $(systemctl status "$s" --no-pager -n 5 2>&1)"
    done
  fi
  redis_password=$(tr -d '[:space:]' < "$f")
fi

redis_host=127.0.0.1
db_host_local=127.0.0.1
# Commands for the site steps, as arrays (run with "${php_exec[@]}" ...)
php_exec=(sudo -u "$linux_user" "/usr/bin/php$php_version")   # artisan as the site user, like PHP-FPM
composer_exec=(sudo -u "$linux_user" env COMPOSER_NO_BLOCKING=1 COMPOSER_NO_AUDIT=1 "/usr/bin/php$php_version" /usr/local/bin/composer)
# db_exec [ARGS]: the database client as root (unix socket login), SQL on stdin: mariadb, or mysql on a
# server that runs MySQL
db_exec() { "$db_client" "$@"; }
verify_dump() { tail -n 30 /var/log/nginx/error.log "/var/log/php$php_version-fpm.log" 2>/dev/null || true; }
