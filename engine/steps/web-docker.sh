# steps/web-docker.sh - docker_stack: the site's PHP container (the files site-docker.sh writes) and
# its nginx vhost. (That an existing vhost of this site was created by deployer is checked in checks.sh.)

section "Site on the docker stack"

task "Check server_name conflicts and the site's current vhost link"
for f in "$stack_nginx_conf"/sites-enabled/*; do
  [[ -e $f && $(basename "$f") != "$site_domain" ]] || continue
  for n in $site_names; do
    if grep -Eq "^[[:space:]]*server_name[[:space:]]+([^;]*[[:space:]])?${n//./\\.}([[:space:]]|;)" "$f"; then
      fail "Conflict: server_name '$n' is already used in $f"
    fi
  done
done
vhost_was_linked=no; [[ ! -L $stack_nginx_conf/sites-enabled/$site_domain ]] || vhost_was_linked=yes

# ---- the same files site-docker.sh writes into the project folder: php/docker.conf and php/php.ini
# when missing (php.ini is edited in the project), and the generated files kept out of git status.
# php/ files are bind-mounted into the container one by one, so they are rewritten in place.
task "Prepare the site's php folder"
d=$project_dir
ensure_dir "$d/php" 0755 "$linux_user" "$site_group"
if [[ -d $d/php ]]; then
  put_content "$d/php/docker.conf" 0644 "$linux_user" "$site_group" --keep < "$ENGINE_DIR/files/docker-site-fpm-global.conf"
  # docker.conf written by an older deployer: add the graceful-reload setting it lacks
  if [[ -f $d/php/docker.conf ]] && ! grep -q '^process_control_timeout' "$d/php/docker.conf"; then
    sed '/^\[global\]/a process_control_timeout = 10s' "$d/php/docker.conf" \
      | put_content "$d/php/docker.conf" 0644 "$linux_user" "$site_group" --inplace
  fi
  docker_conf_changed=$PUT_CHANGED
  if [[ -f $stack_dir/php/site-php.ini ]]; then
    put_content "$d/php/php.ini" 0644 "$linux_user" "$site_group" --keep < "$stack_dir/php/site-php.ini"
  fi
else
  docker_conf_changed=1
fi
if [[ -d $d/.git ]] && ! dry; then
  x=$d/.git/info/exclude; mkdir -p "$d/.git/info"
  for l in /docker-compose.yml /php/; do grep -qxF "$l" "$x" 2>/dev/null || { echo "$l" >> "$x"; changed; }; done
fi

task "Render the site's docker-compose.yml and php/pool.conf"
traffic_mem_limit=${traffic_mem_limit:-1g} traffic_cpus=${traffic_cpus:-2}
put_template docker-site-compose.yml.tpl "$d/docker-compose.yml" 0644 "$linux_user" "$site_group"
put_template docker-site-pool.conf.tpl "$d/php/pool.conf" 0644 "$linux_user" "$site_group" --inplace
pool_changed=$PUT_CHANGED

# docker compose up -d, wait for the site user and the PHP-FPM socket, and reload FPM when only
# pool.conf or php/docker.conf changed (without a recreated container FPM needs a reload)
task "Start or update the site's PHP container"
if dry; then skip "dry run"; else
  out=$(cd -P "$d" && docker compose up -d --remove-orphans 2>&1) || fail "$out"
  case $out in *Creat*|*Recreat*|*Start*) changed ;; esac
  restore_restart_policy "$(cd -P "$d" && docker compose config --format json | jq -r .name)"
  # Not ready after 30 s: the container is recreated once (e.g. the site folder was deleted and made
  # again while it ran: it still has the old, deleted folder mounted, and "up -d" sees nothing to change)
  i=0 recreated=0
  until docker exec "$site_container" id -u "$linux_user" >/dev/null 2>&1 && [[ -S $stack_socket_dir/$site_id.sock ]]; do
    i=$((i + 1))
    if ((i == 10 && ! recreated)); then
      note "not ready after 30 s: recreated the container"
      out=$(cd -P "$d" && docker compose up -d --force-recreate 2>&1) || fail "$out"
      recreated=1 i=0; changed
    fi
    ((i < 20)) || fail "The PHP container did not become ready: $(docker logs --tail 20 "$site_container" 2>&1)"
    sleep 3
  done
  if ((pool_changed || docker_conf_changed)); then
    case $out in *Creat*|*Recreat*) ;; *) (cd -P "$d" && docker compose kill -s SIGUSR2 php >/dev/null); changed ;; esac
  fi
fi

# ---- nginx vhost in the stack's sites-available, enabled with a relative symlink so the link also
# resolves inside the nginx container (where the folder is /etc/nginx).
# Fail-safe: when nginx rejects the new vhost (nginx -t or the reload), the previous one is put back
# and nginx reloaded with it, so the other sites keep running.
vhost=$stack_nginx_conf/sites-available/$site_domain vhost_link=$stack_nginx_conf/sites-enabled/$site_domain
task "Nginx vhost: enable, validate and reload (put back when nginx rejects it)"
put_template site-vhost.conf.tpl "$vhost" 0644 root root --backup
mark_managed "$vhost"
vhost_backup=$PUT_BACKUP vhost_changed=$PUT_CHANGED
[[ $vhost_was_linked == yes ]] || changed
ngx() { docker exec "$stack_nginx_container" nginx "$@"; }
if ! dry; then
  if ! out=$( { ln -sfn "../sites-available/$site_domain" "$vhost_link" && ngx -t && ngx -s reload; } 2>&1 ); then
    rm -f "$vhost_link"
    if [[ -n $vhost_backup ]]; then mv -f "$vhost_backup" "$vhost"
    elif ((vhost_changed)); then rm -f "$vhost"; fi
    if [[ $vhost_was_linked == yes && -e $vhost ]]; then ln -s "../sites-available/$site_domain" "$vhost_link"; fi
    { ngx -t && ngx -s reload; } >/dev/null 2>&1 || true
    fail "nginx rejected the new vhost for $site_domain, so the previous one was put back and the other sites keep running: $out"
  fi
  rm -f ${vhost_backup:+"$vhost_backup"}
fi
