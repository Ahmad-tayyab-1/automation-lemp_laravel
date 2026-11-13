# steps/stack-change-after.sh - after the parts of a stack change are installed and started: a rollback
# whose database server had no kept data folder imports that snapshot's dumps (steps/stack-change.sh).

if [[ -n $db_import_from ]]; then
  section "Database restore"
  task "Import the dumps of snapshot ${db_import_from##*/} into $new" secret
  new_cli=$(db_cli "$new")
  dumps=$(jq -r --arg k "$new" '.dumps // {} | to_entries[] | select(.value == $k) | .key' "$db_import_from/state.json")
  if [[ -z $dumps ]]; then
    skip "the snapshot has no dumps of $new"
  else
    i=0
    until "$new_cli" -N -e 'SELECT 1' >/dev/null 2>&1; do
      i=$((i + 1)); ((i < 30)) || fail "$new does not answer: $("$new_cli" -N -e 'SELECT 1' 2>&1 | tail -n 3)"
      sleep 2
    done
    for name in $dumps; do
      f=$db_import_from/db/$name.sql.gz
      [[ -f $f ]] || { note "WARNING: $f is missing, $name was not imported"; continue; }
      zcat "$f" | "$new_cli" || fail "Importing $name from $f failed"
      note "$name imported"
    done
    note "Database users are not in the dumps: deploy each site again to create its user."
    changed
  fi
fi
