# server/second-db.sh - server part "second-db": a second database server next to the native one on
# 3306, for "keep both" (MariaDB and MySQL packages conflict, so the second one cannot be native):
# MySQL 8.0 or MariaDB 11.4 in a Docker container on 127.0.0.1:3307. Skipped when up to date
# (steps/server-parts.sh).

second_db_port=3307
second_db_native=MariaDB; [[ $second_db_kind == mariadb ]] && second_db_native=MySQL
if [[ $second_db_kind == mariadb ]]; then second_db_image=mariadb:11.4 second_db_label="MariaDB 11.4"
else second_db_image=mysql:8.0 second_db_label="MySQL 8.0"; fi
second_db_container=deployer-$second_db_kind-$second_db_port
second_db_data=/var/lib/deployer/second-db/$second_db_kind

task "Install Docker and the Compose plugin (for the second database)"
if docker --version >/dev/null 2>&1; then :
elif [[ $os_id == ubuntu ]]; then apt_install docker.io docker-compose-v2
else apt_install docker-ce docker-compose-plugin
fi
dry || { systemctl is-active --quiet docker || { systemctl enable --now docker; changed; }; }

task "Root password of the second database" secret
# readable by the container's mysql user (uid/gid 999 in both images), not by other users of the host
f=/etc/deployer/second_db_root_password
if [[ ! -f $f ]]; then changed; dry || { (umask 077; openssl rand -hex 16 > "$f"); }; fi
if ! dry && [[ $(stat -c '%u:%g %a' "$f") != "0:999 640" ]]; then chown 0:999 "$f"; chmod 0640 "$f"; changed; fi

task "Write /opt/deployer-second-db/docker-compose.yml"
ensure_dir /opt/deployer-second-db 0755 root root
ensure_dir "$second_db_data" 0750 root root
put_template second-db-compose.yml.tpl /opt/deployer-second-db/docker-compose.yml 0644 root root

task "Start $second_db_label on 127.0.0.1:$second_db_port"
if dry; then skip "dry run"; else
  [[ -z $(ss -ltn "( sport = :$second_db_port )" 2>/dev/null | tail -n +2) ]] || docker ps -q -f "name=^/$second_db_container$" | grep -q . \
    || fail "Port $second_db_port is already in use: $(ss -ltnp "( sport = :$second_db_port )" | tail -n +2)"
  out=$(docker compose -p deployer-second-db -f /opt/deployer-second-db/docker-compose.yml up -d </dev/null 2>&1) \
    || fail "The second database could not start: $out"
  case $out in *Creat*|*Recreat*|*Start*) changed ;; esac
  docker update --restart=always "$second_db_container" >/dev/null
  i=0
  until docker exec "$second_db_container" sh -c 'mysqladmin ping -uroot -p"$(cat /run/secrets/root_password)" --silent 2>/dev/null || mariadb-admin ping -uroot -p"$(cat /run/secrets/root_password)" --silent 2>/dev/null'; do
    i=$((i + 1)); ((i < 60)) || fail "$second_db_label does not answer: $(docker logs --tail 20 "$second_db_container" 2>&1)"
    sleep 2
  done
fi
