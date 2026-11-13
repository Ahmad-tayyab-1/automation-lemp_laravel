# steps/server-parts.sh - server parts (files in server/). A part runs when:
#   - it never ran on this server (not in /etc/deployer/server.json "applied"),
#   - its files in the engine changed since it last ran (hash of the files listed in "src"),
#   - the file it installs is missing on the server ("probe"),
#   - it is forced (docker-stack: --stack-config or a new webhook), or
#   - deploy.sh --server-refresh was given.
# Otherwise it is skipped, which keeps a deploy to a server that is already set up quick.

section "Server parts"

# What this run needs. A site deploy: nginx, PHP (the site's version), Redis, a database server for a
# local site (MySQL when the server already runs MySQL, else MariaDB) and certbot for a certbot site. "deploy.sh server" (server_only=yes): the parts that were chosen
# (server_components, server_php_versions), with no site.
native_mysql=no; [[ ! -x /usr/sbin/mysqld || -x /usr/sbin/mariadbd ]] || native_mysql=yes
if [[ $server_only == yes ]]; then
  want() { [[ " ${server_components[*]} " == *" $1 "* ]]; }
  want_php_versions=("${server_php_versions[@]}")
else
  want() {
    case $1 in
      nginx|php|redis) return 0 ;;
      mariadb) [[ $deploy_env == local && $native_mysql == no ]] ;;
      mysql)   [[ $deploy_env == local && $native_mysql == yes ]] ;;
      certbot) [[ $tls_mode == certbot ]] ;;
      *) return 1 ;;
    esac
  }
  want_php_versions=("$php_version")
fi
native=no; [[ $docker == yes ]] || native=yes
# use COMPONENT...: "yes" when the run needs all of them ("native" = a native_lemp server), else "no"
use() {
  local c
  for c in "$@"; do
    if [[ $c == native ]]; then [[ $native == yes ]] || { echo no; return 0; }
    else want "$c" || { echo no; return 0; }; fi
  done
  echo yes
}

# name | file in server/ | src (files hashed, relative to engine/) | probe | force | used
server_parts_all=(
  "docker-stack|docker-stack|server/docker-stack.sh templates/docker-stack-*.tpl templates/stack-settings.json.tpl files/docker-stack|$stack_dir/docker-compose.yml|$([[ $stack_configure == true || -n $discord_webhook || -n ${redis_password_new:-} ]] && echo yes || echo no)|$docker"
  "native-base|native-base|server/native-base.sh|/usr/bin/unzip|no|$native"
  "native-nginx|native-nginx|server/native-nginx.sh templates/native-realip.conf.tpl templates/systemd-restart.conf.tpl|/etc/systemd/system/nginx.service.d/deployer-restart.conf|no|$(use native nginx)"
  "native-redis|native-redis|server/native-redis.sh templates/native-redis.conf.tpl|/etc/redis/deployer.conf|$([[ -n ${redis_password_new:-} ]] && echo yes || echo no)|$(use native redis)"
)
if [[ $(use native php) == yes ]]; then
  for v in "${want_php_versions[@]}"; do
    server_parts_all+=("native-php-$v|native-php|server/native-php.sh files/ondrej-php.asc templates/ondrej-php.list.tpl templates/systemd-restart.conf.tpl|/usr/sbin/php-fpm$v|no|yes")
  done
fi
server_parts_all+=(
  "native-mariadb|native-mariadb|server/native-mariadb.sh|/usr/sbin/mariadbd|no|$(use native mariadb)"
  "native-mysql|native-mysql|server/native-mysql.sh|/usr/sbin/mysqld|no|$(use native mysql)"
  "certbot|certbot|server/certbot.sh templates/certbot-deploy-hook.sh.tpl|/etc/letsencrypt/renewal-hooks/deploy/deployer-nginx.sh|no|$(use certbot)"
  # host parts, on both setups ("deploy.sh server" only)
  "clickhouse|clickhouse|server/clickhouse.sh files/clickhouse.asc templates/clickhouse*.tpl templates/systemd-restart.conf.tpl|/etc/clickhouse-server/config.d/deployer-listen.xml|$([[ -n ${clickhouse_password:-} ]] && echo yes || echo no)|$(use clickhouse)"
  "node|node|server/node.sh files/nodesource.asc templates/nodesource.list.tpl|/usr/bin/node|no|$(use node)"
  "second-db|second-db|server/second-db.sh templates/second-db-compose.yml.tpl|/opt/deployer-second-db/docker-compose.yml|$([[ ${second_db_kind:-} == $(sed -n 's/^    image: \([a-z]*\):.*/\1/p' /opt/deployer-second-db/docker-compose.yml 2>/dev/null) ]] && echo no || echo yes)|$(use second-db)"
)

task "Read the server profile and decide which server parts run"
# jq reads and writes /etc/deployer/server.json (every server part installs it too)
if ! command -v jq >/dev/null 2>&1; then
  if dry; then note "would install jq"; else apt_install jq; fi
fi
ensure_dir /etc/deployer 0755 root root
server_profile='{}'
if [[ -f /etc/deployer/server.json ]] && command -v jq >/dev/null 2>&1 && jq -e 'type == "object"' /etc/deployer/server.json >/dev/null 2>&1; then
  server_profile=$(jq -c . /etc/deployer/server.json)
fi
part_hash() { (cd "$ENGINE_DIR" && find $1 -type f -print0 | LC_ALL=C sort -z | xargs -0 cat | sha256sum | cut -c1-16); }
server_parts_run=() server_parts_ok=() server_parts_new=()
for p in "${server_parts_all[@]}"; do
  IFS='|' read -r name file src probe force use <<< "$p"
  [[ $use == yes ]] || continue
  hash=$(part_hash "$src")
  applied='' ran_by_ansible=''
  if command -v jq >/dev/null 2>&1; then
    applied=$(jq -r --arg n "$name" '.applied_bash[$n] // ""' <<< "$server_profile")
    ran_by_ansible=$(jq -r --arg n "$name" '.applied[$n] // ""' <<< "$server_profile")
  fi
  # nginx and Redis were part of native-base before: a server that ran that version has them already
  # (their probe file is there), so they count as changed there, not new
  split_from_base=''
  if [[ $name == native-nginx || $name == native-redis ]] && [[ -e $probe ]] && command -v jq >/dev/null 2>&1; then
    split_from_base=$(jq -r '.applied_bash["native-base"] // .applied["native-base"] // ""' <<< "$server_profile")
  fi
  if [[ $server_refresh == true ]]; then why=refresh
  elif [[ -z $applied && -n $ran_by_ansible ]]; then why="changed"   # set up by the Ansible version
  elif [[ -z $applied && -n $split_from_base ]]; then why="changed"  # split out of native-base
  elif [[ -z $applied ]]; then why=new
  elif [[ ! -e $probe ]]; then why="missing $probe"
  elif [[ $force == yes ]]; then why=settings
  elif [[ $applied != "$hash" ]]; then why=changed
  else why=''
  fi
  if [[ -n $why ]]; then
    server_parts_run+=("$name|$file|$hash|$why")
    [[ $why != new && $why != missing* ]] || server_parts_new+=("$name")
  else
    server_parts_ok+=("$name")
  fi
done
((${#server_parts_ok[@]} == 0)) || note "Up to date, skipped: ${server_parts_ok[*]} (deploy.sh --server-refresh runs them anyway)"
for p in "${server_parts_run[@]}"; do IFS='|' read -r name file hash why <<< "$p"; note "Runs: $name ($why)"; done

# A dry run cannot simulate installing a part that is not on the server yet (its packages and config
# files are missing), so it lists those parts and ends here.
if dry && ((${#server_parts_new[@]})); then
  note "Dry run: a real run installs ${server_parts_new[*]} first. The steps after that cannot be simulated before they are installed, so the dry run ends here."
  task_end
  exit 0
fi

site_php_version=$php_version
for p in "${server_parts_run[@]}"; do
  IFS='|' read -r part_name part_file part_hash_value part_why <<< "$p"
  section "Server part: $part_name ($part_why)"
  [[ $part_name != native-php-* ]] || php_version=${part_name#native-php-}
  # shellcheck source=/dev/null
  source "$ENGINE_DIR/server/$part_file.sh"
done
php_version=$site_php_version
run_handlers

section "Server profile"
# The profile only grows here (parts and PHP versions); a "close" switch removes the closed setup's
# parts (steps/switch-close.sh). "components" describes what the server runs.
task "Record the server profile"
if dry; then
  skip "dry run"
else
  applied_json=$(for p in "${server_parts_run[@]}"; do IFS='|' read -r name file hash why <<< "$p"; printf '%s\t%s\n' "$name" "$hash"; done \
                 | jq -Rn '[inputs | split("\t") | {(.[0]): .[1]}] | add // {}')
  # components: what the server runs (kept from earlier runs of the same setup, plus this run's)
  comps=(); for c in nginx php redis mariadb mysql certbot clickhouse node second-db; do [[ $(use "$c") == no ]] || comps+=("$c"); done
  if [[ $docker == yes ]]; then
    comps=(nginx php redis)
    for c in mariadb certbot clickhouse node; do [[ $(use "$c") == no ]] || comps+=("$c"); done
  fi
  new_profile=$(jq -c --arg setup "$setup_type" --argjson applied "$applied_json" \
      --argjson sel "$(printf '%s\n' "${comps[@]}" | jq -R . | jq -s .)" \
      --argjson phpv "$( ((${#want_php_versions[@]})) && printf '%s\n' "${want_php_versions[@]}" | jq -R . | jq -s . || echo '[]')" '
    . as $p
    | (if ($p.setup // "") == $setup then ($p.components // {}) else {} end) as $prev
    | (if $setup == "docker_stack" then "docker" else "native" end) as $pl
    | ($prev + ([$sel[] | select(. != "php") | {(.): {placement: $pl}}] | add // {})) as $c0
    | (if ($sel | index("php")) then $c0 + {php: {placement: $pl, versions: ((($prev.php.versions // []) + $phpv) | unique | sort)}} else $c0 end) as $c
    | $p + {schema: 1, setup: $setup, components: $c, applied_bash: (($p.applied_bash // {}) + $applied), updated: ($p.updated // "")}' <<< "$server_profile")
  if [[ $(jq -S . <<< "$new_profile") != "$(jq -S . <<< "$server_profile")" ]]; then
    jq -S --indent 4 --arg now "$(date -u +%FT%TZ)" '.updated = $now' <<< "$new_profile" \
      | put_content /etc/deployer/server.json 0644 root root
  fi
fi

task "Record setup marker on target"
if [[ $switch_mode == none && $target_marker != "$setup_type" ]]; then
  printf '%s\n' "$setup_type" | put_content /etc/deployer/setup 0644 root root
fi
