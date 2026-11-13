# steps/database.sh - local database (deploy_env local): created with the site user, then seeded,
# imported or left as is.

section "Local database"

# On docker_stack the MariaDB container is started, then the server is waited for, the database and the
# site user are created (the password is set again), and the tables are counted for the seed and
# import steps.
task "Create the local database and the site's database user" secret
local_db_table_count=0
if dry; then skip "dry run"; else
  if [[ $setup_type == docker_stack ]]; then
    out=$(docker compose -p "$stack_db_project" -f "$stack_dir/db/docker-compose.yml" --env-file "$stack_dir/.env" up -d </dev/null 2>&1) \
      || fail "The MariaDB container could not start: $out"
    restore_restart_policy "$stack_db_project"
  fi
  i=0
  until echo 'SELECT 1;' | db_exec -N >/dev/null 2>&1; do
    i=$((i + 1))
    ((i < 20)) || fail "The database server does not answer: $(echo 'SELECT 1;' | db_exec -N 2>&1 | tail -n 3)"
    sleep 2
  done
  pw=${active_db_password//\\/\\\\}; pw=${pw//\'/\\\'}
  db_exec <<SQL || fail "Creating the database or its user failed (see the MariaDB error log)"
CREATE DATABASE IF NOT EXISTS \`$local_db_name\`;
CREATE USER IF NOT EXISTS '$local_db_user'@'%' IDENTIFIED BY '$pw';
ALTER USER '$local_db_user'@'%' IDENTIFIED BY '$pw';
CREATE USER IF NOT EXISTS '$local_db_user'@'localhost' IDENTIFIED BY '$pw';
ALTER USER '$local_db_user'@'localhost' IDENTIFIED BY '$pw';
GRANT ALL ON \`$local_db_name\`.* TO '$local_db_user'@'%', '$local_db_user'@'localhost'; FLUSH PRIVILEGES;
SQL
  unset pw
  local_db_table_count=$(echo "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = '$local_db_name';" | db_exec -N | tail -n 1)
  if ((local_db_table_count > 0)); then
    case $db_mode in
      seed) note "Notice: Database '$local_db_name' already has $local_db_table_count table(s). Running migrations/seeds..." ;;
      import_backup) note "Notice: Database '$local_db_name' already has $local_db_table_count table(s). Overwriting with backup..." ;;
    esac
  fi
fi

if [[ $db_mode == import_backup ]]; then
  # A site moved between setups imports the dump taken on the server before the switch (move_dump);
  # otherwise the backup comes from the deploy machine (deploy.sh sends it along).
  task "Import the SQL backup into the local database" secret
  if [[ -n $move_dump ]]; then
    backup_file=$move_dump
    [[ -e $backup_file ]] || fail "No database dump at $move_dump on the server (it is written when the site moves away from the old setup)."
  else
    backup_file=$site_db_backup_file
    [[ -e $backup_file ]] || fail "The database backup was not found: $backup_file"
    size=$(stat -L -c %s "$backup_file")
    ((size <= backup_max_bytes)) || fail "Database backup exceeds maximum size: $size > $backup_max_bytes"
  fi
  if dry; then skip "dry run"; else
    if [[ $backup_file == *.gz ]]; then zcat "$backup_file" | db_exec "$local_db_name"
    else db_exec "$local_db_name" < "$backup_file"; fi
    changed
  fi
fi
