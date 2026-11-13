# steps/server-services.sh - "deploy.sh server" only (server_only=yes): the chosen parts are installed by
# steps/server-parts.sh; here their services are enabled and started, and their versions are listed.
# No site is deployed. A later site deploy on this server only adds what it still needs.

section "Services"

if [[ $setup_type == docker_stack ]]; then
  # nginx and Redis containers (and the password files the sites read later)
  source "$ENGINE_DIR/steps/runtime-docker.sh"
  if [[ " ${server_components[*]} " == *" mariadb "* ]]; then
    task "Start the MariaDB container (docker compose up -d)"
    if dry; then skip "dry run"; else
      out=$(docker compose -p "$stack_db_project" -f "$stack_dir/db/docker-compose.yml" --env-file "$stack_dir/.env" up -d </dev/null 2>&1) \
        || fail "The MariaDB container could not start: $out"
      case $out in *Creat*|*Recreat*|*Start*) changed ;; esac
      restore_restart_policy "$stack_db_project"
    fi
  fi

  task "List the stack's containers"
  if dry; then skip "dry run"; else
    # one docker ps per project: two label filters would have to match both
    note "$(for p in "$stack_project" "$stack_db_project"; do
      docker ps --filter "label=com.docker.compose.project=$p" --format '{{.Names}}: {{.Status}} ({{.Image}})' 2>/dev/null || true
    done | sort)"
  fi
else
  services=()
  for c in "${server_components[@]}"; do
    case $c in
      nginx)   services+=(nginx) ;;
      php)     for v in "${server_php_versions[@]}"; do services+=("php$v-fpm"); done ;;
      redis)   services+=(redis-server) ;;
      mariadb) services+=(mariadb) ;;
      mysql)   services+=(mysql) ;;
      certbot) services+=(certbot.timer) ;;
    esac
  done

  task "Enable and start ${services[*]:-(no services)}"
  if dry; then skip "dry run"; elif ((${#services[@]})); then
    systemctl reset-failed "${services[@]}" 2>/dev/null || true
    for s in "${services[@]}"; do
      systemctl is-enabled --quiet "$s" || { systemctl enable --quiet "$s"; changed; }
      systemctl is-active --quiet "$s" || { systemctl start "$s" || fail "Could not start $s: $(systemctl status "$s" --no-pager -n 5 2>&1)"; changed; }
    done
  fi

  task "List what runs on the server"
  if dry; then skip "dry run"; else
    lines=()
    for c in "${server_components[@]}"; do
      case $c in
        nginx)   lines+=("nginx      $(nginx -v 2>&1 | sed 's#^nginx version: ##')  ($(systemctl is-active nginx))") ;;
        php)     for v in "${server_php_versions[@]}"; do
                   lines+=("php $v    $("php$v" -r 'echo PHP_VERSION;' 2>/dev/null)  ($(systemctl is-active "php$v-fpm"), socket /run/php/php$v-fpm.sock)")
                 done
                 lines+=("composer   $(COMPOSER_ALLOW_SUPERUSER=1 composer --version </dev/null 2>/dev/null | awk '{print $3}')") ;;
        redis)   lines+=("redis      $(redis-server --version | grep -o 'v=[0-9.]*' | cut -c3-)  ($(systemctl is-active redis-server), 127.0.0.1:6379, $([[ -s /etc/deployer/redis_password && -n $(tr -d '[:space:]' < /etc/deployer/redis_password) ]] && echo "password in /etc/deployer/redis_password" || echo "no password"))") ;;
        mariadb) lines+=("mariadb    $(mariadb --version | grep -oE '[0-9]+\.[0-9]+\.[0-9]+-MariaDB' | head -n 1)  ($(systemctl is-active mariadb), 127.0.0.1:3306, root: sudo mariadb)") ;;
        mysql)   lines+=("mysql      $(mysqld --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n 1)  ($(systemctl is-active mysql), 127.0.0.1:3306, root: sudo mysql)") ;;
        certbot) lines+=("certbot    $(certbot --version 2>&1 | awk '{print $2}')  (renewal timer $(systemctl is-active certbot.timer))") ;;
      esac
    done
    ((${#lines[@]})) || lines=("(nothing)")
    note "$(printf '%s\n' "${lines[@]}")"
  fi
fi

# host parts, on both setups
task "List the host parts (ClickHouse, Node.js, second database)"
if dry; then skip "dry run"; else
  lines=()
  for c in "${server_components[@]}"; do
    case $c in
      clickhouse)
        systemctl is-enabled --quiet clickhouse-server || { systemctl enable --quiet clickhouse-server; changed; }
        systemctl is-active --quiet clickhouse-server || { systemctl start clickhouse-server || fail "Could not start clickhouse-server: $(systemctl status clickhouse-server --no-pager -n 5 2>&1)"; changed; }
        lines+=("clickhouse $(clickhouse-server --version 2>/dev/null | grep -oE '[0-9]+(\.[0-9]+){3}' | head -n 1 || true)  ($(systemctl is-active clickhouse-server), 127.0.0.1:8123 http / 9000 native, user default, password in /etc/deployer/clickhouse_password)") ;;
      node)
        lines+=("node       $(node -v 2>/dev/null || true)  (npm $(npm -v 2>/dev/null || true))") ;;
      second-db)
        lines+=("$second_db_kind 3307 $(docker inspect -f '{{.Config.Image}} ({{.State.Status}})' "deployer-$second_db_kind-3307" 2>/dev/null || true), 127.0.0.1:3307, root password in /etc/deployer/second_db_root_password") ;;
    esac
  done
  if ((${#lines[@]})); then note "$(printf '%s\n' "${lines[@]}")"; else skip "none chosen"; fi
fi
