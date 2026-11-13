# steps/checks.sh - inputs, OS, setup marker, ports and ownership checks. Read-only.

section "Checks"

task "Validate deployment inputs"
in_list() { local v=$1; shift; [[ " $* " == *" $v "* ]]; }
if [[ $server_only == yes ]]; then
  # deploy.sh server: parts to install, no site
  in_list "$setup_type" docker_stack native_lemp || fail "Invalid setup '$setup_type'."
  for c in "${server_components[@]}"; do
    in_list "$c" nginx php redis mariadb mysql certbot clickhouse node second-db || fail "Unknown server part '$c' (valid: nginx php redis mariadb mysql certbot clickhouse node second-db)."
  done
  has() { [[ " ${server_components[*]} " == *" $1 "* ]]; }
  ! { has mariadb && has mysql; } || fail "Choose MariaDB or MySQL, not both (both use port 3306 and their packages conflict)."
  [[ $setup_type != docker_stack ]] || ! has mysql || fail "The docker stack's database is MariaDB; MySQL is available on native_lemp."
  ! has second-db || [[ $setup_type == native_lemp && $second_db_kind =~ ^(mysql|mariadb)$ ]] || fail "The second database (port 3307) needs native_lemp and second_db_kind mysql or mariadb."
  ! has second-db || ! has "$second_db_kind" || fail "The second database cannot be the same kind as the native one."
  [[ -z $db_swap ]] || { [[ $setup_type == native_lemp && $db_swap =~ ^(mariadb>mysql|mysql>mariadb)$ ]] && in_list "$db_swap_mode" dump delete stop restore; } \
    || fail "Invalid database swap '$db_swap' ($db_swap_mode): native_lemp only, mariadb>mysql or mysql>mariadb, mode dump, delete, stop or restore."
  if [[ $setup_type == native_lemp && -z $db_swap ]]; then
    ! has mysql || [[ ! -x /usr/sbin/mariadbd ]] || fail "MariaDB is installed on this server; MySQL cannot be added next to it."
    ! has mariadb || [[ ! -x /usr/sbin/mysqld || -x /usr/sbin/mariadbd ]] || fail "MySQL is installed on this server; MariaDB cannot be added next to it."
  fi
  for v in "${server_php_versions[@]}"; do
    in_list "$v" 8.0 8.1 8.2 8.3 8.4 || fail "Unsupported PHP version '$v' (8.0 to 8.4)."
  done
  [[ $setup_type != docker_stack ]] || [[ ${server_php_versions[*]} == 8.2 ]] || fail "docker_stack is PHP 8.2 only."
  [[ " ${server_components[*]} " != *" certbot "* || " ${server_components[*]} " == *" nginx "* ]] || fail "certbot needs nginx (it answers Let's Encrypt through nginx)."
elif in_list "$setup_type" docker_stack native_lemp \
  && in_list "$deploy_env" production local \
  && in_list "$db_mode" remote seed import_backup none \
  && ! [[ $deploy_env == local && $db_mode == remote ]] \
  && in_list "$tls_mode" files existing certbot none \
  && { [[ $tls_mode != existing ]] || [[ $tls_cert_path == /* && $tls_key_path == /* ]]; } \
  && in_list "$php_version" 8.0 8.1 8.2 8.3 8.4 \
  && { [[ $setup_type != docker_stack ]] || [[ $php_version == 8.2 ]]; } \
  && in_list "$switch_mode" none stop; then
  :
else
  fail "Invalid deployment inputs. Check setup_type, deploy_env, db_mode, tls_mode, php_version (docker_stack is PHP 8.2 only), switch_mode (move is not supported)."
fi
wants() { [[ $server_only != yes || " ${server_components[*]} " == *" $1 "* ]]; }

task "Check operating system compatibility"
# shellcheck source=/dev/null
os_id=$(. /etc/os-release; echo "${ID:-}") os_version=$(. /etc/os-release; echo "${VERSION_ID:-}")
os_codename=$(. /etc/os-release; echo "${VERSION_CODENAME:-}")
[[ $os_id == ubuntu && ($os_version == 22.04 || $os_version == 24.04) ]] || [[ $os_id == debian && ${os_version%%.*} == 12 ]] \
  || fail "Unsupported OS: $os_id $os_version."

# All read-only checks on the target. It stops with the reason on the first problem.
task "Check the target before changing anything"
busy() { ss -ltnp "( sport = :$1 )" 2>/dev/null | tail -n +2; }
running() { command -v docker >/dev/null 2>&1 && [[ -n $(docker ps -q -f "name=^/$1$" -f "label=com.docker.compose.project=$2") ]]; }

# Setup marker: the machine runs one setup at a time (a "stop" switch closes the other one first)
target_marker=$(head -n 1 /etc/deployer/setup 2>/dev/null || true)
if [[ -n $target_marker && $target_marker != "$setup_type" && $switch_mode != stop ]]; then
  fail "Machine is configured for '$target_marker', cannot deploy with '$setup_type'."
fi

if [[ $setup_type == docker_stack ]]; then
  # docker_stack: no foreign containers with the stack's names; ports free or already ours
  if command -v docker >/dev/null 2>&1; then
    for pair in "$stack_nginx_container:$stack_project" "$stack_redis_container:$stack_project" "$stack_db_container:$stack_db_project"; do
      c=${pair%%:*} p=${pair#*:}
      if [[ -n $(docker ps -a -q -f "name=^/${c}$") && -z $(docker ps -a -q -f "name=^/${c}$" -f "label=com.docker.compose.project=${p}") ]]; then
        fail "Container '$c' already exists on the target but was not created by $stack_dir (compose project '$p')."
      fi
    done
  fi
  if [[ $switch_mode == none ]]; then
    msg=''
    l=$(busy 80; busy 443)
    if [[ -n $l ]] && ! running "$stack_nginx_container" "$stack_project" && ! running nginx webstack; then
      msg="Ports 80/443 are used by another process: $l"
    fi
    l=$(busy 6379)
    if [[ -n $l ]] && ! running "$stack_redis_container" "$stack_project"; then
      msg+="${msg:+$'\n'}Port 6379 is used by another process (a host redis-server?). Stop it first: $l"
    fi
    if { [[ $server_only != yes && $deploy_env == local ]] || [[ $server_only == yes ]] && wants mariadb; }; then
      l=$(busy 3306)
      if [[ -n $l ]] && ! running "$stack_db_container" "$stack_db_project"; then
        msg+="${msg:+$'\n'}Port 3306 is used by another process (a host MariaDB/MySQL?). Stop it first: $l"
      fi
    fi
    [[ -z $msg ]] || fail "$msg"
  fi
  if [[ $server_only != yes ]]; then
    v=$stack_nginx_conf/sites-available/$site_domain
    [[ ! -e $v ]] || is_managed "$v" || fail "$v exists but was not created by deployer. Move it away first."
  fi
else
  # native_lemp: ports 80/443 free or used by nginx; an existing pool and vhost must be ours
  listeners=''; ! wants nginx || listeners=$(busy 80; busy 443)
  if [[ -n $listeners && $switch_mode == none ]]; then
    if ! systemctl is-active --quiet nginx || grep -qv '"nginx"' <<< "$listeners"; then
      fail "Conflict: Ports 80/443 in use by a non-nginx process: $listeners"
    fi
  fi
  if [[ $server_only != yes ]]; then
    for f in /etc/php/*/fpm/pool.d/"$site_id".conf /etc/php/*/fpm/pool.d/"$site_domain".conf /etc/nginx/sites-available/"$site_domain".conf; do
      [[ ! -f $f ]] || is_managed "$f" || fail "$f exists but was not created by deployer. Move it away first."
    done
  fi
fi

# Fail-safe: never start changing a server whose nginx config is already broken, since every reload
# would then fail for all its sites. An error that names this site is allowed: this deploy rewrites the
# site's vhost. Skipped for a setup switch (the new setup's nginx is not running yet).
if [[ $switch_mode == none ]]; then
  bad='' err=''
  if [[ $setup_type == docker_stack ]]; then
    if [[ -n $(docker ps -q --filter "name=^${stack_nginx_container}$" --filter status=running 2>/dev/null) ]]; then
      err=$(docker exec "$stack_nginx_container" nginx -t 2>&1) || bad=1
    fi
  elif command -v nginx >/dev/null 2>&1; then
    err=$(nginx -t 2>&1) || bad=1
  fi
  if [[ -n $bad ]] && { [[ $server_only == yes ]] || ! grep -qF "$site_domain" <<< "$err"; }; then
    fail "nginx's configuration was already invalid before this deploy, so nothing was changed (reloading it would fail for every site on the server):
$err
Fix the file that nginx -t names, then deploy again."
  fi
fi
