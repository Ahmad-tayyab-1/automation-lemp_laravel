# steps/stack-change.sh - "deploy.sh server" and "deploy.sh rollback" (server_only=yes): before the chosen
# parts are installed (steps/server-parts.sh), a snapshot of the server is taken, the parts that are no
# longer wanted are stopped, and a database swap (MariaDB <-> MySQL) is prepared.
#
#   stack_remove     parts to stop: nginx redis mariadb mysql certbot clickhouse node second-db php-<V>
#                    (stopped and disabled, never purged: their packages, config and data stay; node is
#                    a runtime without a service, so it is uninstalled)
#   db_swap          "OLD>NEW" (mariadb>mysql or mysql>mariadb): the native database server changes;
#   db_swap_mode     what happens to OLD's data:
#                      dump    every database is dumped into the snapshot, then the data folder is deleted
#                      delete  the data folder is deleted, no dump
#                      stop    the data folder is kept in /var/lib/deployer/db-data/OLD (switching back
#                          later puts it back)
#                      restore (rollback) like stop; NEW gets its kept data folder back, or the dumps of
#                          snapshot $restore_snapshot are imported (steps/stack-change-after.sh)
#   restore_snapshot the snapshot a rollback returns to
#
# Snapshots: /var/lib/deployer/snapshots/<id>/state.json (what ran before this change), server.json,
# setup, etc.tgz (the config folders) and db/<name>.sql.gz (dump mode). deploy.sh rollback reads them.

section "Stack change"

snap_root=/var/lib/deployer/snapshots
data_aside=/var/lib/deployer/db-data
# part -> its systemd unit
part_unit() {
  case $1 in
    nginx) echo nginx ;; redis) echo redis-server ;; mariadb) echo mariadb ;; mysql) echo mysql ;;
    certbot) echo certbot.timer ;; clickhouse) echo clickhouse-server ;; php-*) echo "php${1#php-}-fpm" ;;
  esac
}
# part -> its name in server.json "applied_bash" and "components"
part_applied() {
  case $1 in
    nginx|redis|mariadb|mysql) echo "native-$1" ;; php-*) echo "native-php-${1#php-}" ;; *) echo "$1" ;;
  esac
}
# part_state PART: on (installed and enabled), off (installed, disabled) or absent
part_state() {
  local p=$1 bin='' u
  case $p in
    nginx) bin=/usr/sbin/nginx ;; redis) bin=/usr/bin/redis-server ;; mariadb) bin=/usr/sbin/mariadbd ;;
    mysql) [[ -x /usr/sbin/mariadbd ]] || bin=/usr/sbin/mysqld ;; clickhouse) bin=/usr/bin/clickhouse-server ;;
    certbot) bin=$(command -v certbot || true) ;; php-*) bin=/usr/sbin/php-fpm${p#php-} ;;
    node) [[ -x /usr/bin/node ]] && echo on || echo absent; return 0 ;;
    second-db)
      if [[ -n $(docker ps -q -f 'name=^/deployer-(mysql|mariadb)-3307$' 2>/dev/null) ]]; then echo on
      elif [[ -n $(docker ps -aq -f 'name=^/deployer-(mysql|mariadb)-3307$' 2>/dev/null) ]]; then echo off
      else echo absent; fi
      return 0 ;;
    stack-mariadb)
      if [[ -n $(docker ps -q -f "name=^/$stack_db_container$" 2>/dev/null) ]]; then echo on
      elif [[ -n $(docker ps -aq -f "name=^/$stack_db_container$" 2>/dev/null) ]]; then echo off
      else echo absent; fi
      return 0 ;;
  esac
  if [[ -z $bin || ! -e $bin ]]; then echo absent; return 0; fi
  u=$(part_unit "$p")
  if systemctl is-enabled --quiet "$u" 2>/dev/null; then echo on; else echo off; fi
}
# drop_from_profile PART: the part must run again when it is wanted later (it starts its service)
drop_from_profile() {
  local f=/etc/deployer/server.json a c
  [[ -f $f ]] || return 0
  a=$(part_applied "$1") c=$1
  if [[ $1 == php-* ]]; then
    jq --indent 4 --arg a "$a" --arg v "${1#php-}" '
      (.applied, .applied_bash) |= ((. // {}) | del(.[$a]))
      | if .components.php then .components.php.versions = ((.components.php.versions // []) - [$v]) else . end
      | if (.components.php.versions // [1]) == [] then del(.components.php) else . end' "$f" > "$f.tmp"
  else
    jq --indent 4 --arg a "$a" --arg c "$c" '(.applied, .applied_bash) |= ((. // {}) | del(.[$a])) | .components |= ((. // {}) | del(.[$c]))' "$f" > "$f.tmp"
  fi
  mv "$f.tmp" "$f" && chmod 0644 "$f"
}
db_kind_native() { if [[ -x /usr/sbin/mariadbd ]]; then echo mariadb; elif [[ -x /usr/sbin/mysqld ]]; then echo mysql; fi; }
# the database client for KIND (as root over the unix socket)
db_cli() { if [[ $1 == mariadb ]]; then echo mariadb; else echo mysql; fi; }

# ---- 1. snapshot
task "Take a snapshot of the server (for deploy.sh rollback)"
snapshot_id=$(date +%Y%m%d-%H%M%S)
snap=$snap_root/$snapshot_id
if dry; then skip "dry run"; else
  install -d -m 0700 "$snap_root" "$snap"
  php_states='{}' parts_json='{}'
  for p in nginx redis mariadb mysql certbot clickhouse node second-db; do
    parts_json=$(jq -c --arg p "$p" --arg s "$(part_state "$p")" '. + {($p): $s}' <<< "$parts_json")
  done
  [[ $setup_type != docker_stack && ${switch_from:-} != docker_stack ]] || \
    parts_json=$(jq -c --arg s "$(part_state stack-mariadb)" '. + {"stack-mariadb": $s}' <<< "$parts_json")
  for b in /usr/sbin/php-fpm[0-9]*; do
    [[ -e $b ]] || continue
    v=${b#/usr/sbin/php-fpm}
    php_states=$(jq -c --arg v "$v" --arg s "$(part_state "php-$v")" '. + {($v): $s}' <<< "$php_states")
  done
  second_kind=$(docker ps -a --format '{{.Names}}' 2>/dev/null | sed -n 's/^deployer-\(mysql\|mariadb\)-3307$/\1/p' | head -n 1 || true)
  jq -n --arg id "$snapshot_id" --arg label "${snapshot_label:-stack change}" --arg setup "$(head -n 1 /etc/deployer/setup 2>/dev/null || true)" \
    --argjson parts "$parts_json" --argjson php "$php_states" --arg native "$(db_kind_native)" --arg second "$second_kind" \
    '{id: $id, time: (now | todate), label: $label, setup: $setup, parts: $parts, php: $php,
      db: {native: $native, second: $second}, dumps: {}}' > "$snap/state.json"
  cp -a /etc/deployer/server.json "$snap/server.json" 2>/dev/null || true
  cp -a /etc/deployer/setup "$snap/setup" 2>/dev/null || true
  dirs=(); for d in /etc/nginx /etc/php /etc/redis /etc/mysql /etc/clickhouse-server /etc/deployer /etc/cron.d/laravel-schedulers /opt/deployer-second-db; do [[ ! -e $d ]] || dirs+=("$d"); done
  tar -czf "$snap/etc.tgz" "${dirs[@]}" 2>/dev/null || true
  chmod -R go-rwx "$snap"
  note "snapshot $snapshot_id in $snap"
  # the newest 20 are kept (older ones, with their dumps, are deleted)
  for old_snap in $(ls -1 "$snap_root" | sort -r | tail -n +21); do rm -rf "${snap_root:?}/$old_snap"; done
  changed
fi

# ---- 2. setup switch (a server without sites moves between native_lemp and docker_stack):
# steps/switch-close.sh closes the old setup first, from run.sh

# ---- 3. stop the parts that are no longer wanted
for p in "${stack_remove[@]}"; do
  case $p in
    node)
      task "Uninstall Node.js (no service to stop)"
      if dry; then changed; note "would remove nodejs"
      elif dpkg-query -W -f='${Status}' nodejs 2>/dev/null | grep -q 'install ok installed'; then
        apt_get remove nodejs; changed
      fi ;;
    second-db)
      task "Stop the second database container (its data stays in /var/lib/deployer/second-db)"
      if dry; then changed; note "would stop and remove the container"
      elif [[ -f /opt/deployer-second-db/docker-compose.yml ]]; then
        docker compose -p deployer-second-db -f /opt/deployer-second-db/docker-compose.yml down </dev/null >/dev/null 2>&1 || true; changed
      fi ;;
    stack-mariadb)
      task "Stop the stack's MariaDB container ($stack_db_container); its data stays"
      if dry; then changed; note "would stop $stack_db_container"
      else
        docker update --restart=no "$stack_db_container" >/dev/null 2>&1 || true
        docker stop "$stack_db_container" >/dev/null 2>&1 || true; changed
      fi ;;
    *)
      u=$(part_unit "$p")
      task "Stop and disable $u (packages, config and data stay)"
      if dry; then changed; note "would stop and disable $u"
      else
        systemctl disable --now "$u" >/dev/null 2>&1 || true; changed
      fi ;;
  esac
  dry || drop_from_profile "$p"
done

# ---- 4. database swap
db_import_from=''
if [[ -n ${db_swap:-} ]]; then
  old=${db_swap%%>*} new=${db_swap#*>}
  [[ $(db_kind_native) == "$old" ]] || fail "The server does not run $old (it runs '$(db_kind_native)'), so it cannot be swapped to $new."
  old_cli=$(db_cli "$old")

  if [[ $db_swap_mode == dump ]]; then
    task "Dump every database of $old into the snapshot" secret
    if dry; then changed; note "would dump every database into $snap/db/"
    else
      systemctl start "$(part_unit "$old")"
      install -d -m 0700 "$snap/db"
      dump=mariadb-dump; [[ $old == mariadb ]] || dump=mysqldump
      dumps='{}'
      for name in $("$old_cli" -N -e 'SHOW DATABASES' | grep -vxE 'mysql|information_schema|performance_schema|sys' || true); do
        "$dump" --single-transaction --routines --triggers --events --databases "$name" | gzip > "$snap/db/$name.sql.gz.tmp" \
          || fail "Dumping database $name failed; nothing was changed yet."
        gzip -t "$snap/db/$name.sql.gz.tmp" && mv "$snap/db/$name.sql.gz.tmp" "$snap/db/$name.sql.gz"
        dumps=$(jq -c --arg n "$name" --arg k "$old" '. + {($n): $k}' <<< "$dumps")
        note "$name: $(zcat "$snap/db/$name.sql.gz" | grep -c '^CREATE TABLE' || true) tables"
      done
      jq --argjson d "$dumps" '.dumps = $d' "$snap/state.json" > "$snap/state.json.tmp" && mv "$snap/state.json.tmp" "$snap/state.json"
      chmod -R go-rwx "$snap"
      changed
    fi
  fi

  # The data folder is moved aside or dumped first (next task), so purging is safe: it removes the old
  # server's config in /etc/mysql too, which the new one would otherwise read and refuse to start with
  # (my.cnf would still point to mariadb.cnf, with MariaDB-only options). The old config is in etc.tgz.
  task "Stop $old ($new replaces it on port 3306)"
  if dry; then changed; note "would stop $old"
  else
    systemctl disable --now "$(part_unit "$old")" >/dev/null 2>&1 || true
    changed
  fi

  task "The data of $old: $db_swap_mode"
  if dry; then changed
    case $db_swap_mode in
      dump)   note "would delete /var/lib/mysql (the dumps are in the snapshot)" ;;
      delete) note "would delete /var/lib/mysql (no dump)" ;;
      *)      note "would move /var/lib/mysql to $data_aside/$old" ;;
    esac
  elif [[ -d /var/lib/mysql ]]; then
    case $db_swap_mode in
      dump|delete) rm -rf /var/lib/mysql ;;
      *)
        install -d -m 0700 "$data_aside"
        [[ ! -e $data_aside/$old ]] || mv "$data_aside/$old" "$data_aside/$old.$snapshot_id"
        mv /var/lib/mysql "$data_aside/$old"
        note "kept in $data_aside/$old" ;;
    esac
    changed
  fi

  task "Purge the $old packages and their config (the config is in the snapshot)"
  if dry; then changed; note "would purge the $old server and client packages"
  else
    if [[ $old == mariadb ]]; then pat='^(mariadb-|galera-)'
    else pat='^mysql-(server|client)'; fi
    pkgs=$(dpkg-query -W -f='${db:Status-Abbrev} ${Package}\n' 2>/dev/null | awk -v p="$pat" '$1 ~ /^[ihr]/ && $2 ~ p {print $2}' | xargs)
    [[ -z $pkgs ]] || apt_get purge $pkgs
    update-alternatives --auto my.cnf >/dev/null 2>&1 || true
    changed
  fi
  dry || drop_from_profile "$old"
fi

# ---- 5. a native database server that is installed now (by a swap, or again after it was removed):
# its kept data folder is used again, else a rollback imports the snapshot's dumps after it starts
new=''
for k in mariadb mysql; do
  [[ " ${server_components[*]} " == *" $k "* && $setup_type == native_lemp ]] || continue
  if [[ -n $db_swap ]] || [[ -z $(db_kind_native) ]]; then new=$k; fi
done
if [[ -n $new ]]; then
  task "Put back the data folder $new had before (if it was kept)"
  if dry; then skip "dry run"
  elif [[ -d $data_aside/$new && ! -e /var/lib/mysql ]]; then
    mv "$data_aside/$new" /var/lib/mysql
    note "the data folder of $new from $data_aside/$new is used again"
    changed
  elif [[ -n $restore_snapshot ]]; then
    db_import_from=$snap_root/$restore_snapshot
    skip "no kept folder; the dumps of snapshot $restore_snapshot (if any) are imported after $new starts"
  else
    skip "none: $new starts empty"
  fi
  dry || drop_from_profile "$new"
fi
