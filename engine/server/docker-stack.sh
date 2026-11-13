# server/docker-stack.sh - server part "docker-stack": Docker, /opt/docker-stack (files, configs,
# images) and the watchdog. Skipped when up to date (steps/server-parts.sh). Starting the stack and
# reading its passwords happen on every deploy in steps/runtime-docker.sh.

task "Install Docker and the Compose plugin"
if docker --version >/dev/null 2>&1; then :
elif [[ $os_id == ubuntu ]]; then apt_install docker.io docker-compose-v2
else apt_install docker-ce docker-compose-plugin
fi

task "Ensure the Docker service is started and enabled"
if dry; then skip "dry run"; else
  systemctl is-enabled --quiet docker || { systemctl enable --quiet docker; changed; }
  systemctl is-active --quiet docker || { systemctl start docker; changed; }
fi

task "Install tools used by the stack scripts"
apt_install curl jq python3

# ---- SETUP.md steps 1-3: users, folders, permissions
task "Check www-data is uid 33 and gid 33 (the stack images create 33:33)"
w=$(getent passwd www-data | cut -d: -f3-4)
[[ $w == 33:33 ]] || fail "www-data on this server is ${w:-missing}, the stack needs 33:33."

task "Ensure the redis user exists (the redis container runs as this user)"
if ! getent group redis >/dev/null; then changed; dry || groupadd --system redis; fi
if ! getent passwd redis >/dev/null; then
  changed; dry || useradd --system -g redis -s /usr/sbin/nologin -d /var/lib/redis -M redis
fi
redis_uid=$(getent passwd redis | cut -d: -f3 || true) redis_gid=$(getent passwd redis | cut -d: -f4 || true)
redis_uid=${redis_uid:-0} redis_gid=${redis_gid:-0}

task "Create stack folders"
for d in "$stack_dir" "$stack_dir/db" "$stack_dir/redis" "$stack_nginx_conf/sites-available" "$stack_nginx_conf/sites-enabled" \
         "$stack_nginx_conf/snippets" "$stack_nginx_conf/conf.d" "$stack_nginx_conf/cert" "$stack_nginx_conf/modules-enabled" "$tls_dir"; do
  ensure_dir "$d" 0755 root root
done
ensure_dir "$stack_socket_dir" 0755 www-data www-data
ensure_dir /run/redis 0755 redis redis
ensure_dir /var/lib/redis 0750 redis redis
ensure_dir /var/log/nginx 0755 root adm

# Everything under /run is wiped on boot. php-docker.conf is SETUP.md step 3; the redis one is added by
# the deployer, without it the redis container cannot create its socket.
task "Recreate /run/php-docker and /run/redis after a reboot"
printf 'd %s 0755 www-data www-data -\n' "$stack_socket_dir" | put_content /etc/tmpfiles.d/php-docker.conf 0644 root root
printf 'd /run/redis 0755 redis redis -\n' | put_content /etc/tmpfiles.d/docker-stack-redis.conf 0644 root root

# ---- stack files: files/docker-stack is copied over on every run of this part; the server's own
# config files (nginx.conf, redis.conf, watchdog.conf, blockips.conf) are written only when missing,
# so edits made on the server survive.
task "Copy docker-stack files (scripts, Dockerfiles, units, stock nginx includes)"
while IFS= read -r -d '' f; do
  rel=${f#"$ENGINE_DIR/files/docker-stack/"}
  [[ -d $(dirname "$stack_dir/$rel") ]] || { changed; dry || install -d -m 0755 "$(dirname "$stack_dir/$rel")"; }
  put_content "$stack_dir/$rel" "$(stat -c %a "$f")" root root < "$f"
done < <(find "$ENGINE_DIR/files/docker-stack" -type f -print0)

task "Write the server config files when missing (edit them on the server)" secret
stack_redis_had_conf=no; [[ ! -f $stack_dir/redis/redis.conf ]] || stack_redis_had_conf=yes
stack_redis_want=${redis_password_new:-}; [[ $stack_redis_want != none ]] || stack_redis_want=''
if [[ $stack_redis_had_conf == no ]]; then
  stack_new_redis_password=$stack_redis_want
  [[ -n $stack_new_redis_password || ${redis_password_new:-} == none ]] || stack_new_redis_password=$(openssl rand -hex 24)
else stack_new_redis_password=''; fi
stack_redis_old_password=$(sed -n 's/^requirepass \([^ ]*\).*/\1/p' "$stack_dir/redis/redis.conf" 2>/dev/null | head -n 1 || true)
put_template docker-stack-nginx.conf.tpl "$stack_dir/nginx/conf/nginx.conf" 0644 root root --keep
put_template docker-stack-redis.conf.tpl "$stack_dir/redis/redis.conf" 0640 root root --keep --secret
put_template docker-stack-watchdog.conf.tpl "$stack_dir/watchdog/watchdog.conf" 0600 root root --keep --secret
unset stack_new_redis_password

# a new Redis password for a stack that runs already: requirepass in redis.conf (the rest of the file
# is yours and stays), Redis restarted, and every site's .env gets it now
if [[ -n ${redis_password_new:-} && $stack_redis_had_conf == yes && $stack_redis_want != "$stack_redis_old_password" ]]; then
  task "Set the new Redis password (redis/redis.conf requirepass)" secret
  changed
  if ! dry; then
    f=$stack_dir/redis/redis.conf
    if [[ -z $stack_redis_want ]]; then
      sed -i "s|^requirepass .*|# requirepass (none: no password, chosen in deploy.sh server; Redis listens on 127.0.0.1 only)|" "$f"
    elif grep -q '^requirepass ' "$f"; then
      sed -i "s|^requirepass .*|requirepass $stack_redis_want|" "$f"
    elif grep -q '^# requirepass (none' "$f"; then
      sed -i "s|^# requirepass (none.*|requirepass $stack_redis_want|" "$f"
    else
      printf 'requirepass %s\n' "$stack_redis_want" >> "$f"
    fi
    if docker ps -q --filter "name=^${stack_redis_container}\$" | grep -q .; then docker restart "$stack_redis_container" >/dev/null; fi
  fi
  task "Give the sites the new Redis password (.env)" secret
  update_sites_redis_password docker_stack "$stack_redis_want"
fi

task "Create the IP block list when missing (snippets/blockips.conf)"
put_content "$stack_nginx_conf/snippets/blockips.conf" 0644 root root --keep < /dev/null

task "Render the stack docker-compose.yml and the local MariaDB compose file"
put_template docker-stack-compose.yml.tpl "$stack_dir/docker-compose.yml" 0644 root root
put_template docker-stack-db-compose.yml.tpl "$stack_dir/db/docker-compose.yml" 0644 root root

task "Make redis.conf readable by the redis container only"
if [[ -f $stack_dir/redis/redis.conf ]] && ! dry; then
  [[ $(stat -c '%a %U %g' "$stack_dir/redis/redis.conf") == "640 root $redis_gid" ]] \
    || { chown "root:$redis_gid" "$stack_dir/redis/redis.conf"; chmod 0640 "$stack_dir/redis/redis.conf"; changed; }
fi

# ---- MariaDB root password (.env); reused from /opt/php-stack when its data is taken over
task "Write the stack .env (MariaDB root password)" secret
adopt_legacy_db=no
if [[ ! -e $stack_dir/.env && ! -e $stack_dir/db/data/mysql && -e $legacy_stack_dir/.env && -e $legacy_stack_dir/db/data/mysql ]]; then
  adopt_legacy_db=yes
fi
if [[ ! -e $stack_dir/.env ]]; then
  if [[ $adopt_legacy_db == yes ]]; then
    stack_db_root_password=$(sed -n 's/^DB_ROOT_PASSWORD=\([^[:space:]]*\).*/\1/p' "$legacy_stack_dir/.env" | head -n 1)
  else
    stack_db_root_password=$(openssl rand -hex 24)
  fi
  put_template docker-stack.env.tpl "$stack_dir/.env" 0600 root root --secret
  unset stack_db_root_password
fi

# ---- the previous docker setup (/opt/php-stack): stop it, keep every file
task "Stop the previous docker setup ($legacy_stack_dir) when it still runs"
legacy_ids=$(for p in webstack webstack-db php-stack-db; do docker ps -a -q --filter "label=com.docker.compose.project=$p" 2>/dev/null; done | sort -u)
if [[ -z $legacy_ids ]]; then
  skip "none"
else
  changed
  note "Replacing the previous docker setup in $legacy_stack_dir: $(wc -l <<< "$legacy_ids") container(s) are stopped and removed. Files, site folders and database data stay. Sites still on it are offline until they are deployed again."
  if ! dry; then
    if [[ $adopt_legacy_db == yes ]]; then
      docker stop mariadb >/dev/null 2>&1 || true
      cp -a "$legacy_stack_dir/db/data" "$stack_dir/db/data"
      note "copied $legacy_stack_dir/db/data to $stack_dir/db/data"
    fi
    for p in webstack webstack-db php-stack-db; do
      ids=$(docker ps -a -q --filter "label=com.docker.compose.project=$p")
      [[ -z $ids ]] || docker rm -f $ids >/dev/null
    done
    docker network rm webstack_web >/dev/null 2>&1 || true
    printf '%s\n' "Replaced by $stack_dir on $(date -u +%FT%TZ). Containers removed; files kept." > "$legacy_stack_dir/REPLACED-BY-docker-stack.txt"
  fi
fi

# ---- server settings asked by deploy.sh (first install or --stack-config)
task "Write allowed IPs (staging lock) and rate-limit whitelist snippets"
keep=--keep; [[ $stack_configure != true ]] || keep=''
put_template docker-stack-admin-ips.conf.tpl "$stack_nginx_conf/snippets/allowed_admin_ips.conf" 0644 root root $keep
put_template docker-stack-whitelist-ips.conf.tpl "$stack_nginx_conf/snippets/whitelist_ips.conf" 0644 root root $keep

task "Set the Discord webhook for container alerts" secret
if [[ -n $discord_webhook && -f $stack_dir/watchdog/watchdog.conf ]]; then
  line_in_file "$stack_dir/watchdog/watchdog.conf" '^DISCORD_WEBHOOK=' "DISCORD_WEBHOOK=\"$discord_webhook\""
else
  skip "no new webhook"
fi
if [[ -f $stack_dir/watchdog/watchdog.conf ]] && ! dry; then chown root "$stack_dir/watchdog/watchdog.conf"; chmod 0600 "$stack_dir/watchdog/watchdog.conf"; fi
stack_watchdog_on=false
grep -Eq '^DISCORD_WEBHOOK="https://' "$stack_dir/watchdog/watchdog.conf" 2>/dev/null && stack_watchdog_on=true

task "Record the stack settings (read by deploy.sh to know the stack is set up)"
if [[ $stack_configure == true ]]; then
  # a JSON list laid out like Ansible's to_nice_json did (4 spaces, one item per line)
  json_list() { local -n a=$1; if ((${#a[@]})); then printf '%s\n' "${a[@]}" | jq -Rn --indent 4 '[inputs]' | sed '2,$s/^/    /'; else echo '[]'; fi; }
  stack_admin_ips_json=$(json_list stack_admin_ips) stack_whitelist_ips_json=$(json_list stack_whitelist_ips)
  now_iso=$(date -u +%FT%TZ)
  put_template stack-settings.json.tpl "$stack_dir/.deployer-stack.json" 0644 root root
else
  skip "settings unchanged"
fi

# ---- SETUP.md step 4: check before building
task "Run check-docker.sh"
if dry; then skip "dry run"; else
  check_rc=0; check_out=$(bash "$stack_dir/check-docker.sh" 2>&1) || check_rc=$?
  check_out=$(sed 's/\x1b\[[0-9;]*m//g' <<< "$check_out")
  w=$(grep -E 'WARN|FAIL|passed' <<< "$check_out" || true)
  [[ -z $w ]] || note "$w"
  ((check_rc == 0)) || fail "check-docker.sh failed:
$check_out"
fi

# ---- SETUP.md steps 5-6: images, rebuilt only when missing or when their build files changed
task "Build the shared PHP and nginx images"
build_image() {
  local sum stamp
  sum=$(find "$2" -maxdepth 1 -type f -exec cat {} + | sha256sum | cut -c1-16)
  stamp="$stack_dir/.image-$(tr '/:' '__' <<< "$1")"
  if docker image inspect "$1" >/dev/null 2>&1 && [[ $(cat "$stamp" 2>/dev/null) == "$sum" ]]; then return 0; fi
  changed
  if dry; then note "would build $1"; return 0; fi
  docker build -q -t "$1" "$2" >/dev/null
  echo "$sum" > "$stamp"
  note "built $1"
}
build_image "$stack_php_image" "$stack_dir/base-image"
build_image "$stack_nginx_image" "$stack_dir/nginx"

task "Install and start the container watchdog (Discord alerts + auto-restart)"
if [[ $stack_watchdog_on != true ]]; then
  skip "no webhook"
elif dry; then
  skip "dry run"
else
  units_changed=0
  for u in container-watchdog.service container-watchdog.timer container-events.service; do
    put_content "/etc/systemd/system/$u" 0644 root root < "$stack_dir/watchdog/$u"
    ((! PUT_CHANGED)) || units_changed=1
  done
  ((! units_changed)) || systemctl daemon-reload
  for u in container-watchdog.timer container-events.service; do
    systemctl is-enabled --quiet "$u" || { systemctl enable --quiet "$u"; changed; }
    if ((units_changed)); then systemctl restart "$u"
    else systemctl is-active --quiet "$u" || { systemctl start "$u"; changed; }
    fi
  done
fi
