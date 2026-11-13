# steps/env.sh - the application .env: created from .env.example, APP_KEY, the DB password, and the
# managed keys from templates/app-env.tpl (plus "env_extra" from sites.json).

section "Application .env"

# In order:
#   1. .env from .env.example (or empty), owned by the site user, mode 0600
#   2. lines whose variable name has parentheses are commented out (invalid dotenv names)
#   3. APP_KEY generated when missing
#   4. local: the database password from /etc/deployer/db_pass_<user>, generated once;
#      production: the password from deploy.sh (asked, or DEPLOY_DB_PASSWORD)
#   5. managed and extra keys set: the last "KEY=" line is replaced, or the key is appended
task "Write the application .env" secret
env_file=$project_dir/.env

if [[ $deploy_env == local ]]; then
  pf=/etc/deployer/db_pass_$site_id
  if [[ ! -f $pf ]] && ! dry; then
    ( umask 077; printf 'DB_PASSWORD=%s\n' "$(openssl rand -hex 16)" > "$pf" )
  fi
  active_db_password=$(sed -n 's/^DB_PASSWORD=//p' "$pf" 2>/dev/null | head -n 1 | tr -d '[:space:]' || true)
else
  active_db_password=$db_password
fi

app_debug=true; [[ $deploy_env != production ]] || app_debug=false
app_url=http://$site_domain; [[ $tls_mode == none ]] || app_url=https://$site_domain
env_db_connection=${site_db_connection:-mysql}
if [[ $deploy_env == production ]]; then
  env_db_host=$site_db_host env_db_port=${site_db_port:-3306} env_db_name=$site_db_name env_db_user=$site_db_user
else
  env_db_host=$db_host_local env_db_port=3306 env_db_name=$local_db_name env_db_user=$local_db_user
fi

if [[ -f $env_file ]]; then
  mapfile -t env_lines < "$env_file"; env_new=0
elif [[ -f $project_dir/.env.example ]]; then
  mapfile -t env_lines < "$project_dir/.env.example"; env_new=1
else
  env_lines=(); env_new=1
fi

# 2. invalid names, e.g. "MAIL_FROM_NAME(optional)=..."
for i in "${!env_lines[@]}"; do
  [[ ${env_lines[i]} =~ ^[[:space:]]*[^=#]*\(.*\)[^=]*= ]] && env_lines[i]="# ${env_lines[i]}"
done

# env_put KEY VALUE: the last "KEY=" line becomes KEY="VALUE", or it is appended
env_put() {
  local k=$1 v=$2 i last=-1
  v=${v//\\/\\\\}; v=${v//\"/\\\"}; v=${v//\$/\\\$}
  for i in "${!env_lines[@]}"; do [[ ${env_lines[i]} != "$k="* ]] || last=$i; done
  if ((last >= 0)); then env_lines[last]="$k=\"$v\""; else env_lines+=("$k=\"$v\""); fi
}

# 3. APP_KEY
has_key=0
for l in "${env_lines[@]}"; do [[ ! $l =~ ^APP_KEY=.+ ]] || has_key=1; done
((has_key)) || env_put APP_KEY "base64:$(head -c 32 /dev/urandom | base64 -w0)"

# 5. managed keys (templates/app-env.tpl), then env_extra
redis_env_password=${redis_password:-null}   # Redis without a password: null (Laravel: no AUTH)
tpl_render app-env.tpl > "$ENGINE_TMP/app-env" || fail "templates/app-env.tpl could not be rendered"
while IFS= read -r l; do
  [[ $l == *=* ]] || continue
  env_put "${l%%=*}" "${l#*=}"
done < "$ENGINE_TMP/app-env"
rm -f "$ENGINE_TMP/app-env"
for i in "${!site_env_extra_keys[@]}"; do env_put "${site_env_extra_keys[i]}" "${site_env_extra_vals[i]}"; done

printf '%s\n' "${env_lines[@]}" > "$ENGINE_TMP/env"
if ((env_new)) || ! cmp -s "$ENGINE_TMP/env" "$env_file"; then
  changed
  if dry; then
    if ((env_new)); then note "would create $env_file"
    else
      keys=$( { diff <(grep -v '^#' "$env_file" | sort) <(grep -v '^#' "$ENGINE_TMP/env" | sort) || true; } | sed -n 's/^> \([^=]*\)=.*/\1/p' | sort -u | tr '\n' ' ')
      note "would change these keys in $env_file: ${keys:-(comments only)}"
    fi
  else
    install -m 0640 -o "$linux_user" -g www-data "$ENGINE_TMP/env" "$env_file.deployer-tmp"
    mv -f "$env_file.deployer-tmp" "$env_file"
  fi
fi
rm -f "$ENGINE_TMP/env"
if [[ -f $env_file ]] && ! dry; then chown "$linux_user:www-data" "$env_file"; chmod 0640 "$env_file"; fi
