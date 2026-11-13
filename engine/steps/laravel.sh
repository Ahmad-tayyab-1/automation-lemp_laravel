# steps/laravel.sh - Laravel steps: composer, storage link, migrations, seeder, production caches,
# scheduler cron.

section "Laravel"

# A composer.lock that git does not track was written by an earlier composer install on this server, for
# the PHP version of that time. Resolve again instead of trusting it (a committed lock is never touched).
task "Run composer install"
if dry; then skip "dry run"; else
  cd -P "$project_dir"
  git ls-files --error-unmatch composer.lock >/dev/null 2>&1 || rm -f composer.lock
  composer_args=(install --optimize-autoloader); [[ $deploy_env != production ]] || composer_args=(install --no-dev --optimize-autoloader)
  composer_out=$("${composer_exec[@]}" "${composer_args[@]}" 2>&1) || { printf '%s\n' "$composer_out"; fail "composer install failed:
$(tail -n 20 <<< "$composer_out")"; }
  printf '%s\n' "$composer_out"
  [[ $composer_out == *'Nothing to install, update or remove'* ]] || changed
  cd /
fi

# Only for a Laravel app (artisan present):
#   - public/storage -> storage/app/public when missing (apps that store files on the "public" disk)
#   - artisan migrate (--force in production) when run_migrations is on, or a seeded database is empty
#   - artisan db:seed for --db-mode seed (local only)
#   - config, route and view caches in production
#   - the scheduler, as site-docker.sh suggests: one line per site in /etc/cron.d/laravel-schedulers,
#     tagged "# deployer:<domain>" so manual lines in the same file are never touched. On by default for
#     production only: a local copy running the scheduler could send real mails or run real jobs.
task "Run the artisan steps and set the scheduler cron line"
if dry; then skip "dry run"
elif [[ ! -f $project_dir/artisan ]]; then skip "not a Laravel app"
else
  cd -P "$project_dir"
  if [[ ! -e public/storage && ! -L public/storage ]]; then "${php_exec[@]}" artisan storage:link; changed; fi
  if [[ $site_run_migrations == true ]] || [[ $db_mode == seed && ${local_db_table_count:-0} == 0 ]]; then
    if [[ $deploy_env == production ]]; then "${php_exec[@]}" artisan migrate --force; else "${php_exec[@]}" artisan migrate; fi
    changed
  fi
  if [[ $deploy_env == local && $db_mode == seed ]]; then "${php_exec[@]}" artisan db:seed; changed; fi
  # Views compiled by the code being replaced go
  "${php_exec[@]}" artisan view:clear >/dev/null
  if [[ $deploy_env == production ]]; then
    for c in config:cache route:cache view:cache; do "${php_exec[@]}" artisan $c; done
  fi
  cd /
  f=/etc/cron.d/laravel-schedulers tag=" # deployer:$site_domain"
  others() { [[ ! -f $f ]] || awk -v t="$tag" 'substr($0, length($0) - length(t) + 1) != t' "$f"; }
  scheduler=$site_scheduler; [[ -n $scheduler ]] || { scheduler=false; [[ $deploy_env != production ]] || scheduler=true; }
  if [[ $scheduler == true ]]; then
    if [[ $setup_type == docker_stack ]]; then
      want="* * * * * root /usr/bin/docker exec -u $linux_user $site_container php artisan schedule:run >/dev/null 2>&1$tag"
    else
      want="* * * * * $linux_user cd $project_dir && /usr/bin/php$php_version artisan schedule:run >/dev/null 2>&1$tag"
    fi
    if ! grep -qxF "$want" "$f" 2>/dev/null; then
      { others; echo "$want"; } > "$f.deployer-tmp"; chmod 0644 "$f.deployer-tmp"; mv "$f.deployer-tmp" "$f"; changed
    fi
  elif [[ -f $f ]] && [[ $(others | wc -l) != $(wc -l < "$f") ]]; then
    others > "$f.deployer-tmp"; chmod 0644 "$f.deployer-tmp"; mv "$f.deployer-tmp" "$f"; changed
  fi
fi

# composer and artisan wrote new files: they get the same permissions
task "Set the project permissions again"
if dry; then skip "dry run"; else set_site_permissions "$project_dir"; fi
