# steps/runtime-docker.sh - every docker_stack deploy: the stack is up, and the site steps get the Redis
# password, the MariaDB root password and the docker exec commands.

section "Docker stack runtime"

# restore_restart_policy PROJECT: a machine switch (steps/switch-close.sh) sets restart=no on every
# compose container, and "docker compose up -d" starts an unchanged container again without
# recreating it, so the policy would stay "no" and the site would not come back after a reboot.
# Every compose file of the stack and the sites says "restart: always".
restore_restart_policy() {
  local id
  for id in $(docker ps -aq --filter "label=com.docker.compose.project=$1"); do
    [[ $(docker inspect -f '{{.HostConfig.RestartPolicy.Name}}' "$id") == no ]] || continue
    docker update --restart=always "$id" >/dev/null
    changed
  done
}

# docker compose up -d in /opt/docker-stack, wait until nginx accepts its config and redis answers,
# then read the Redis password (redis.conf) and the MariaDB root password (.env).
task "Start nginx and redis (docker compose up -d) and read the stack passwords" secret
for f in "$stack_dir/redis/redis.conf" "$stack_dir/.env"; do
  [[ -f $f ]] || dry || fail "$f is missing. Deploy again with --server-refresh to recreate the stack files."
done
if ! dry; then
  out=$(cd "$stack_dir" && docker compose -p "$stack_project" up -d 2>&1) || fail "$out"
  case $out in *Creat*|*Recreat*|*Start*) changed ;; esac
  restore_restart_policy "$stack_project"
  i=0
  until docker exec "$stack_nginx_container" nginx -t -q 2>/dev/null \
        && docker exec "$stack_redis_container" redis-cli ping 2>&1 | grep -qE 'PONG|NOAUTH'; do
    i=$((i + 1))
    ((i < 20)) || fail "The stack did not become ready: $(docker exec "$stack_nginx_container" nginx -t 2>&1)"
    sleep 3
  done
fi
redis_password=$(sed -n 's/^requirepass \([^ ]*\).*/\1/p' "$stack_dir/redis/redis.conf" 2>/dev/null | head -n 1 || true)
stack_db_root_password=$(sed -n 's/^DB_ROOT_PASSWORD=\([^ ]*\).*/\1/p' "$stack_dir/.env" 2>/dev/null | head -n 1 || true)

redis_host=127.0.0.1
db_host_local=127.0.0.1
php_exec=(docker exec -u "$linux_user" "$site_container" php)   # artisan as the site user, like PHP-FPM
composer_exec=(docker exec -e COMPOSER_NO_BLOCKING=1 -e COMPOSER_NO_AUDIT=1 -u "$linux_user" "$site_container" composer)
# db_exec [ARGS]: the mariadb client as root, SQL on stdin. MYSQL_PWD is passed in the environment
# (never on the command line, where ps would show it).
db_exec() { MYSQL_PWD=$stack_db_root_password docker exec -i -e MYSQL_PWD "$stack_db_container" mariadb -uroot "$@"; }
verify_dump() { docker logs --tail 30 "$site_container" 2>&1; tail -n 20 /var/log/nginx/error.log 2>/dev/null || true; }
