# steps/web-native.sh - native_lemp: the site's PHP-FPM pool and its nginx vhost.
# Fail-safe: each file is checked (php-fpm -t, nginx -t) and reloaded; when the check or the reload
# fails, the previous file is put back and the service reloaded with it, so other sites keep running.

section "Site on native nginx and PHP-FPM"

task "Check server_name conflicts and the site's current vhost link"
for f in /etc/nginx/sites-enabled/*; do
  [[ -e $f && $(basename "$f") != "$site_domain.conf" ]] || continue
  if grep -Eq "^[[:space:]]*server_name[[:space:]]+([^;]*[[:space:]])?${site_domain//./\\.}([[:space:]]|;)" "$f"; then
    fail "Conflict: server_name '$site_domain' is already used in $f"
  fi
done
vhost_was_linked=no; [[ ! -L /etc/nginx/sites-enabled/$site_domain.conf ]] || vhost_was_linked=yes

pool_file=/etc/php/$php_version/fpm/pool.d/$site_id.conf
task "PHP-FPM pool (put back when PHP-FPM rejects it)"
put_template native-pool.conf.tpl "$pool_file" 0644 root root --backup
pool_backup=$PUT_BACKUP pool_changed=$PUT_CHANGED
# A pool from an older deploy is named after the domain and may use the same socket: it goes first
old_pool=/etc/php/$php_version/fpm/pool.d/$site_domain.conf old_pool_copy=''
if [[ $old_pool != "$pool_file" && -f $old_pool ]]; then
  pool_changed=1; changed
  if ! dry; then old_pool_copy=$ENGINE_TMP/old-pool.conf; mv -f "$old_pool" "$old_pool_copy"; fi
fi
if ((pool_changed)) && ! dry; then
  if ! out=$( { "php-fpm$php_version" -t && systemctl reload "php$php_version-fpm"; } 2>&1 ); then
    rm -f "$pool_file"
    [[ -z $pool_backup ]] || mv -f "$pool_backup" "$pool_file"
    [[ -z $old_pool_copy ]] || mv -f "$old_pool_copy" "$old_pool"
    { "php-fpm$php_version" -t && systemctl reload "php$php_version-fpm"; } >/dev/null 2>&1 || true
    fail "The new PHP-FPM pool for $site_domain was rejected, so the previous one was put back: $out"
  fi
fi

# What the vhost format needs at the http level: $block_ip, and the /admin allow list. Both IP lists are
# yours to edit: they are only written when missing.
task "Blocked IPs (\$block_ip) and the /admin allow list"
ensure_dir /etc/nginx/snippets 0755 root root
put_template native-blockips.conf.tpl /etc/nginx/snippets/blockips.conf 0644 root root --keep
put_template native-admin-ips.conf.tpl /etc/nginx/snippets/allowed_admin_ips.conf 0644 root root --keep
if ! grep -Rqs --exclude=deployer-block-ip.conf 'geo[[:space:]]*\$block_ip' /etc/nginx/nginx.conf /etc/nginx/conf.d; then
  put_template native-block-ip.conf.tpl /etc/nginx/conf.d/deployer-block-ip.conf 0644 root root
fi

mark_managed "$pool_file"
vhost=/etc/nginx/sites-available/$site_domain.conf vhost_link=/etc/nginx/sites-enabled/$site_domain.conf
# Always reloaded (graceful): a re-created sites-enabled link or a certificate change is not visible to
# nginx otherwise, e.g. after a switch back from docker_stack the vhost file is unchanged but its link
# was removed and nginx was started without it.
task "Nginx vhost: enable, validate and reload (put back when nginx rejects it)"
put_template site-vhost.conf.tpl "$vhost" 0644 root root --backup
vhost_backup=$PUT_BACKUP vhost_changed=$PUT_CHANGED
[[ $vhost_was_linked == yes ]] || changed
if ! dry; then
  if ! out=$( { ln -sfn "$vhost" "$vhost_link" && nginx -t && systemctl reload nginx; } 2>&1 ); then
    rm -f "$vhost_link"
    if [[ -n $vhost_backup ]]; then mv -f "$vhost_backup" "$vhost"
    elif ((vhost_changed)); then rm -f "$vhost"; fi
    if [[ $vhost_was_linked == yes && -e $vhost ]]; then ln -s "$vhost" "$vhost_link"; fi
    { nginx -t && { systemctl is-active --quiet nginx && systemctl reload nginx || systemctl start nginx; }; } >/dev/null 2>&1 || true
    fail "nginx rejected the new vhost for $site_domain, so the previous one was put back and the other sites keep running: $out"
  fi
fi

mark_managed "$vhost"

# The backups were only needed until the new files were accepted, and a pool of this site left under
# another PHP version (the site moved to a new version) is removed
task "Remove the backup copies and old PHP-FPM pools of other PHP versions"
if dry; then skip "dry run"; else
  rm -f ${pool_backup:+"$pool_backup"} ${vhost_backup:+"$vhost_backup"}
  for f in /etc/php/*/fpm/pool.d/"$site_domain".conf /etc/php/*/fpm/pool.d/"$site_id".conf; do
    [[ -f $f ]] || continue
    ver=$(cut -d/ -f4 <<< "$f")
    if [[ $ver != "$php_version" ]] && is_managed "$f"; then
      rm -f "$f"; changed
      if systemctl is-active --quiet "php$ver-fpm"; then systemctl reload "php$ver-fpm" || true; fi
    fi
  done
fi
