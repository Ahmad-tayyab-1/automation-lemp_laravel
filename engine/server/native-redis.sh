# server/native-redis.sh - server part "native-redis": redis-server with a password
# (/etc/deployer/redis_password) and FLUSHALL/DEBUG disabled. Skipped when up to date
# (steps/server-parts.sh).

restart_redis() {
  task "Restart redis-server (its configuration changed)"
  if dry; then skip "dry run"; else systemctl restart redis-server; changed; fi
}

task "Install Redis"
apt_install redis-server

task "Native Redis password" secret
ensure_dir /etc/deployer 0755 root root
# the password typed in deploy.sh (redis_password_new; "none" = no password: the file is empty), else a
# random one; kept on later runs
redis_old_password=$(tr -d '[:space:]' < /etc/deployer/redis_password 2>/dev/null || true)
redis_want=${redis_password_new:-}; [[ $redis_want != none ]] || redis_want=''
redis_change=no redis_had_file=no; [[ ! -f /etc/deployer/redis_password ]] || redis_had_file=yes
[[ -z ${redis_password_new:-} || ( $redis_want == "$redis_old_password" && -f /etc/deployer/redis_password ) ]] || redis_change=yes
if [[ $redis_change == yes ]]; then
  changed
  dry || { printf '%s\n' "$redis_want" | put_content /etc/deployer/redis_password 0600 root root --secret; }
elif [[ ! -f /etc/deployer/redis_password ]]; then
  changed
  dry || { openssl rand -hex 16 | put_content /etc/deployer/redis_password 0600 root root --secret; }
fi
redis_password=$(tr -d '[:space:]' < /etc/deployer/redis_password 2>/dev/null || true)

task "Render native Redis configuration snippet" secret
put_template native-redis.conf.tpl /etc/redis/deployer.conf 0640 redis redis --secret
((! PUT_CHANGED)) || notify restart_redis

task "Ensure Redis includes deployer snippet"
line_in_file /etc/redis/redis.conf '^include /etc/redis/deployer\.conf$' "include /etc/redis/deployer.conf"
((! PUT_CHANGED)) || notify restart_redis

# Exactly once, in redis.conf: renaming a command that is already renamed makes redis refuse to start.
task "Disable FLUSHALL and DEBUG in redis.conf"
for cmd in FLUSHALL DEBUG; do
  line_in_file /etc/redis/redis.conf "^[[:space:]]*rename-command[[:space:]]+$cmd[[:space:]]" "rename-command $cmd \"\""
  ((! PUT_CHANGED)) || notify restart_redis
done

# a new password (or none) on a server that has sites: they get it now, not only on their next deploy
if [[ $redis_change == yes && $redis_had_file == yes ]]; then
  task "Give the sites the new Redis password (.env)" secret
  update_sites_redis_password native_lemp "$redis_want"
fi
