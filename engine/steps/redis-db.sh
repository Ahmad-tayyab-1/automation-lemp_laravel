# steps/redis-db.sh - the site's two Redis databases (sessions/queue and cache), recorded in
# /etc/deployer/redis-dbs.

section "Redis databases"

# A site keeps the pair it has. A new site gets the next free pair = highest number in use + 1 (made
# even): counting lines would hand out numbers that are still in use once a line is removed.
# redis.conf "databases": 200 in the docker-stack config, 256 in the deployer's native config.
task "Find or register the site's Redis database pair"
reg=/etc/deployer/redis-dbs
[[ -f $reg ]] || dry || install -m 0644 -o root /dev/null "$reg"
line=$(grep -E "^([0-9]+[[:space:]]+[0-9]+[[:space:]]+)?${site_domain//./\\.}\$" "$reg" 2>/dev/null | head -n 1 || true)
read -r a b c <<< "$line"
if [[ -n ${c:-} ]]; then
  site_redis_db=$a site_redis_cache_db=$b
else
  max=$(awk '{for (i = 1; i <= NF; i++) if ($i ~ /^[0-9]+$/) print $i}' "$reg" 2>/dev/null | sort -n | tail -1 || true)
  next=$(( ${max:--1} + 1 )); next=$(( next + next % 2 ))
  limit=256; [[ $setup_type != docker_stack ]] || limit=200
  if ((next + 1 >= limit)); then
    fail "No free Redis database left for $site_domain (needs $next and $((next + 1))). Raise 'databases' in redis.conf or remove unused lines from $reg."
  fi
  site_redis_db=$next site_redis_cache_db=$((next + 1))
  changed; note "new pair: $next $((next + 1))"
  dry || echo "$next $((next + 1)) $site_domain" >> "$reg"
fi
