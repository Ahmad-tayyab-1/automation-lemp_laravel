# engine/lib/files.sh - writing files and packages, with dry-run diffs (Ansible's template, copy,
# file, lineinfile and apt modules).
#
#   put_template TPL DEST MODE OWNER GROUP [options]   render templates/TPL and write it to DEST
#   put_content DEST MODE OWNER GROUP [options] < text  write stdin to DEST
#     options:  --backup   keep the old file as DEST.<pid>.<date>@<time>~ when it changes;
#                          its path is left in PUT_BACKUP (empty when there was none)
#               --secret   never show a diff (the file holds a password)
#               --keep     write only when DEST does not exist (a file edited on the server stays)
#               --inplace  overwrite the existing file instead of replacing it: needed for a file
#                          bind-mounted into a container, which would keep seeing the old one
#     The file is written only when its content differs; mode and owner are fixed when they differ.
#     PUT_CHANGED is 1 when something changed (and the task is marked changed).
#   ensure_dir PATH MODE OWNER GROUP
#   line_in_file FILE REGEX LINE        replace the last line matching REGEX (extended), or append LINE
#   apt_install PACKAGE...              install the packages that are missing
#   apt_get ARGS...                     apt-get without questions (install, remove, update)

PUT_CHANGED=0 PUT_BACKUP=''

# Pool and vhost files carry no comment: the ones the deployer wrote are listed here instead. Files from
# older deploys still have the "managed by deployer" line.
managed_list=/etc/deployer/managed-files
is_managed() { grep -qxF "$1" "$managed_list" 2>/dev/null || grep -sq 'managed by deployer' "$1"; }
mark_managed() {
  dry && return 0
  install -d -m 0755 /etc/deployer
  grep -qxF "$1" "$managed_list" 2>/dev/null || echo "$1" >> "$managed_list"
}

# set_site_permissions DIR: owner site user, group www-data; folders 755 and files 655; the folders in
# storage, bootstrap/cache and config 775; .env 0640. Not .git (git's own files), and not the files of a
# Docker site that put_content manages (php/, docker-compose.yml).
set_site_permissions() {
  local d=$1 x
  chown -R "$site_uid:www-data" "$d"
  find "$d" \( -path "$d/.git" -o -path "$d/php" -o -path "$d/docker-compose.yml" \) -prune -o -type d -exec chmod 0755 {} +
  find "$d" \( -path "$d/.git" -o -path "$d/php" -o -path "$d/docker-compose.yml" \) -prune -o -type f -exec chmod 0655 {} +
  for x in storage bootstrap/cache config; do
    [[ ! -d $d/$x ]] || find "$d/$x" -type d -exec chmod 0775 {} +
  done
  [[ ! -f $d/.env ]] || chmod 0640 "$d/.env"
}

put_template() {
  local tpl=$1; shift
  local out=$ENGINE_TMP/render
  tpl_render "$tpl" > "$out" || fail "Template $tpl could not be rendered: $(tail -n 3 "$out" 2>/dev/null)"
  put_content "$@" < "$out"
}

put_content() {
  local dest=$1 mode=$2 owner=$3 group=$4; shift 4
  local backup=0 secret=0 keep=0 inplace=0 o new=$ENGINE_TMP/new attrs
  for o in "$@"; do
    case $o in --backup) backup=1 ;; --secret) secret=1 ;; --keep) keep=1 ;; --inplace) inplace=1 ;; esac
  done
  PUT_CHANGED=0 PUT_BACKUP=''
  cat > "$new"
  if [[ -e $dest ]] && ((keep)); then rm -f "$new"; return 0; fi
  if [[ -e $dest ]] && cmp -s "$new" "$dest"; then
    attrs=$(stat -c '%a %U %G' "$dest")
    if [[ $attrs != "${mode#0} $owner $group" ]]; then
      PUT_CHANGED=1; changed
      if dry; then note "would set $dest to mode $mode, owner $owner:$group (now $attrs)"
      else chmod "$mode" "$dest"; chown "$owner:$group" "$dest"; fi
    fi
    rm -f "$new"; return 0
  fi
  PUT_CHANGED=1; changed
  if dry; then
    if ((secret)); then
      note "would write $dest (content hidden: it holds a password)"
    elif [[ -e $dest ]]; then
      note "$(diff -u --label "$dest (now)" --label "$dest (new)" "$dest" "$new" | head -n 80)"
    else
      note "would create $dest:
$(head -n 40 "$new" | sed 's/^/+/')$( (($(wc -l < "$new") > 40)) && printf '\n+... (%d lines)' "$(wc -l < "$new")")"
    fi
    rm -f "$new"; return 0
  fi
  if ((backup)) && [[ -e $dest ]]; then
    PUT_BACKUP="$dest.$$.$(date +%F@%T)~"
    cp -p "$dest" "$PUT_BACKUP"
  fi
  if ((inplace)) && [[ -e $dest ]]; then
    cat "$new" > "$dest"; rm -f "$new"
  else
    install -m "$mode" -o "$owner" -g "$group" "$new" "$dest.deployer-tmp"
    mv -f "$dest.deployer-tmp" "$dest"; rm -f "$new"
  fi
  chmod "$mode" "$dest"; chown "$owner:$group" "$dest"
}

ensure_dir() {
  local path=$1 mode=$2 owner=$3 group=$4 attrs
  if [[ ! -d $path ]]; then
    changed
    if dry; then note "would create the folder $path"; else install -d -m "$mode" -o "$owner" -g "$group" "$path"; fi
    return 0
  fi
  attrs=$(stat -c '%a %U %G' "$path")
  if [[ $attrs != "${mode#0} $owner $group" ]]; then
    changed
    if dry; then note "would set $path to mode $mode, owner $owner:$group (now $attrs)"
    else chmod "$mode" "$path"; chown "$owner:$group" "$path"; fi
  fi
}

line_in_file() {
  local file=$1 regex=$2 line=$3 out=$ENGINE_TMP/lif
  PUT_CHANGED=0
  if [[ -f $file ]] && grep -qxF -- "$line" "$file" && [[ $(grep -Ec -- "$regex" "$file") -le 1 ]]; then return 0; fi
  awk -v re="$regex" -v line="$line" '
    { l[NR] = $0; if ($0 ~ re) last = NR }
    END { for (i = 1; i <= NR; i++) print (i == last ? line : l[i]); if (!last) print line }' "$file" > "$out"
  if cmp -s "$out" "$file"; then return 0; fi
  PUT_CHANGED=1; changed
  if dry; then note "$(diff -u --label "$file (now)" --label "$file (new)" "$file" "$out")"; return 0; fi
  cat "$out" > "$file"
}

# apt_get ARGS: apt-get that never asks: a long lock wait (a freshly booted Ubuntu runs
# unattended-upgrades for a while), and a config file changed on the server is kept (no dpkg question)
apt_get() {
  DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=900 -o Dpkg::Options::=--force-confdef \
    -o Dpkg::Options::=--force-confold -y -q "$@" </dev/null
}

apt_install() {
  local p missing=()
  for p in "$@"; do
    [[ $(dpkg-query -W -f='${Status}' "$p" 2>/dev/null) == "install ok installed" ]] || missing+=("$p")
  done
  ((${#missing[@]})) || return 0
  changed
  if dry; then note "would install: ${missing[*]}"; return 0; fi
  apt_update_if_old
  apt_get install "${missing[@]}"
}

# apt-get update when the package lists are older than an hour (Ansible's cache_valid_time: 3600)
apt_update_if_old() {
  local stamp=/var/lib/apt/periodic/update-success-stamp f=/var/cache/apt/pkgcache.bin
  [[ -e $stamp ]] || stamp=$f
  if [[ ${1:-} == force || ! -e $stamp ]] || (($(date +%s) - $(stat -c %Y "$stamp") > 3600)); then
    apt_get update
    touch "$f"
  fi
}

# update_sites_redis_password SETUP PASSWORD: after a Redis password change ('' = none), every site of SETUP on this
# server (/etc/deployer/sites/*.json) gets REDIS_PASSWORD=PASSWORD in its .env, and a cached config
# (bootstrap/cache/config.php, production) is built again, so the sites keep working before their next
# deploy. The password has no characters that are special to sed or to .env (deploy.sh checks it).
update_sites_redis_password() {
  local setup=$1 pw=$2 f dom user owner php dir env out
  for f in /etc/deployer/sites/*.json; do
    [[ -f $f ]] || continue
    [[ $(jq -r '.setup // empty' "$f") == "$setup" && $(jq -r '.status // "active"' "$f") != stopped ]] || continue
    dom=$(jq -r '.domain' "$f"); user=$(jq -r '.site_id // .linux_user // empty' "$f"); owner=$(jq -r '.linux_user // empty' "$f"); php=$(jq -r '.php_version // empty' "$f")
    dir=$(jq -r '.project_folder // empty' "$f"); [[ -n $dir ]] || dir=$sites_root/$dom
    env=$dir/.env
    [[ -f $env ]] && grep -q '^REDIS_PASSWORD=' "$env" || continue
    changed
    if dry; then note "would write the new password to $env"; continue; fi
    # no password: null (Laravel's env() makes it null; an empty string would be sent to AUTH)
    sed -i "s|^REDIS_PASSWORD=.*|REDIS_PASSWORD=\"${pw:-null}\"|" "$env"
    if [[ -f $dir/bootstrap/cache/config.php ]]; then
      if [[ $setup == docker_stack ]]; then
        out=$(docker exec -u "$owner" "${user//[_.]/-}-php" php artisan config:cache 2>&1) || true
      else
        out=$(cd "$dir" && sudo -u "$owner" "/usr/bin/php$php" artisan config:cache 2>&1) || true
      fi
      # when the cache cannot be built, it is removed: Laravel then reads .env (the new password)
      [[ $out == *"cached successfully"* ]] || rm -f "$dir/bootstrap/cache/config.php"
    fi
    note "$dom: .env has $([[ -n $pw ]] && echo "the new password" || echo "no password (REDIS_PASSWORD=null)")"
  done
}

