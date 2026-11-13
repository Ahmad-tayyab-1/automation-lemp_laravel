# steps/switch-close.sh - machine setup switch (switch_mode "stop"): close the old setup before the new
# one is installed. Both setups need ports 80/443 (and docker_stack also 6379/3306 on the host network).
# The sites that move are deployed again on the new setup by deploy.sh after this run.

section "Close the previous setup ($switch_from)"

if dry; then
  task "Planned machine switch"
  note "Dry run: close ${#switch_site_domains[@]} site(s) on $switch_from before setting up $switch_to"
fi

# Before anything stops: dump the local databases of the sites that move to the new setup. A failed
# dump fails the run here, while the old setup is still serving.
for i in "${!switch_site_domains[@]}"; do
  d=${switch_site_domains[i]} u=${switch_site_users[i]} e=${switch_site_envs[i]}
  [[ $e == local && " ${dump_sites[*]} " == *" $d "* ]] || continue
  task "Dump the local database of $d (moving to $switch_to)" secret
  if dry; then skip "dry run"; continue; fi
  install -d -m 700 /var/lib/deployer/moves
  f=/var/lib/deployer/moves/$d.sql.gz
  if [[ $switch_from == docker_stack ]]; then
    P=$(sed -n 's/^DB_ROOT_PASSWORD=//p' "$stack_dir/.env")
    docker exec -e MYSQL_PWD="$P" "$stack_db_container" mariadb-dump -uroot --single-transaction --routines --triggers "$u" | gzip > "$f.tmp"
  else
    dump=mariadb-dump; command -v mariadb-dump >/dev/null 2>&1 || dump=mysqldump
    "$dump" --single-transaction --routines --triggers "$u" | gzip > "$f.tmp"
  fi
  gzip -t "$f.tmp" && mv "$f.tmp" "$f" && chmod 600 "$f"
  note "$d: $(zcat "$f" | grep -c '^CREATE TABLE' || true) tables -> $f"
  changed
done

if ! dry; then
  task "Stop and disable the $switch_from services"
  if [[ $switch_from == native_lemp ]]; then
    systemctl stop nginx redis-server mariadb mysql 2>/dev/null || true
    systemctl disable nginx redis-server mariadb mysql 2>/dev/null || true
    for s in $(systemctl list-unit-files 'php*-fpm.service' --no-legend 2>/dev/null | awk '{print $1}'); do
      systemctl stop "$s" 2>/dev/null || true; systemctl disable "$s" 2>/dev/null || true
    done
    rm -f /etc/nginx/sites-enabled/* 2>/dev/null || true
  else
    # restart=no first: with "restart: always" a stopped container comes back when Docker restarts.
    systemctl disable --now container-watchdog.timer container-events.service 2>/dev/null || true
    ids=$(docker ps -a -q --filter label=com.docker.compose.project 2>/dev/null || true)
    if [[ -n $ids ]]; then
      docker update --restart=no $ids >/dev/null 2>&1 || true
      docker stop $ids >/dev/null 2>&1 || true
    fi
  fi
  sed -i '/ # deployer:/d' /etc/cron.d/laravel-schedulers 2>/dev/null || true
  changed

  task "Mark the closed sites as stopped in /etc/deployer/sites/"
  mkdir -p /etc/deployer/sites
  for d in "${switch_site_domains[@]}"; do
    f=/etc/deployer/sites/$d.json
    if [[ -f $f ]]; then
      jq '.status = "stopped"' "$f" > "$f.tmp" && mv "$f.tmp" "$f" && chmod 0644 "$f"
    else
      printf '{"domain":"%s","status":"stopped","setup":"%s"}\n' "$d" "$switch_from" > "$f" && chmod 0644 "$f"
    fi
  done
  changed

  task "Update the setup marker"
  printf '%s\n' "$setup_type" | put_content /etc/deployer/setup 0644 root root

  # The old setup's services are stopped and disabled now, so its server parts must run again if the
  # server ever switches back (they start and enable the services).
  task "Forget the closed setup's server parts in /etc/deployer/server.json"
  f=/etc/deployer/server.json
  if [[ -f $f ]]; then
    pfx=docker-; [[ $switch_from != native_lemp ]] || pfx=native-
    jq --indent 4 --arg p "$pfx" '(.applied, .applied_bash) |= ((. // {}) | with_entries(select(.key | startswith($p) | not)))' "$f" > "$f.tmp" \
      && mv "$f.tmp" "$f" && chmod 0644 "$f"
  fi
fi
