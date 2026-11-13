# steps/code.sh - project folder, git clone or update, and file permissions.

section "Code"

# git runs as the site user, with the key in its own ~/.ssh
site_git() { ( cd / && runuser -u "$linux_user" -- env HOME="$site_home" git "$@" ); }

# Like Ansible's git module with force: the folder ends up exactly at the branch, tag or commit; local
# changes to tracked files are discarded, untracked files (.env, vendor/, storage/) are kept.
task "Clone or update the site's git repository"
d=$project_dir repo=$site_repo ver=${site_branch:-main}
if dry; then
  if [[ -d $d/.git ]]; then
    note "a real run fetches and checks out '$ver' (now at $(git -C "$d" log -1 --format='%h %s' 2>/dev/null | cut -c1-70 || echo '?'))"
  else
    note "would clone $repo into $d"
    changed
  fi
else
  install -d -m 0755 -o root -g root "$sites_root"
  [[ -d $d ]] || install -d -m 0755 -o "$site_uid" -g www-data "$d"
  cloned=''
  if [[ -d $d/.git ]]; then
    # all of it, not only .git: the site may just have moved to another user, who must own the files
    chown -R "$site_uid:www-data" "$d"
    before=$(site_git -C "$d" rev-parse -q --verify HEAD || true)
    [[ $(site_git -C "$d" remote get-url origin 2>/dev/null) == "$repo" ]] \
      || site_git -C "$d" remote set-url origin "$repo" 2>/dev/null || site_git -C "$d" remote add origin "$repo"
  else
    before=''
    if [[ -n $(ls -A "$d") ]]; then fail "$d is not empty and is not a git checkout. Move its files away first."; fi
    site_git clone --quiet --no-checkout "$repo" "$d"   # fetches every branch and tag already
    cloned=1
  fi
  site_git -C "$d" config --unset core.fileMode 2>/dev/null || true   # set by older deploys
  [[ -n $cloned ]] || site_git -C "$d" fetch --quiet --force --prune origin '+refs/heads/*:refs/remotes/origin/*' '+refs/tags/*:refs/tags/*'
  if site_git -C "$d" rev-parse -q --verify "refs/remotes/origin/$ver^{commit}" >/dev/null; then
    site_git -C "$d" checkout --quiet --force -B "$ver" "refs/remotes/origin/$ver"
  elif target=$(site_git -C "$d" rev-parse -q --verify "$ver^{commit}"); then
    site_git -C "$d" checkout --quiet --force --detach "$target"
  else
    fail "Branch, tag or commit '$ver' not found in $repo"
  fi
  [[ $(site_git -C "$d" rev-parse HEAD) == "$before" ]] || { changed; note "now at $(site_git -C "$d" log -1 --format='%h %s' | cut -c1-80)"; }
fi

task "Set the project owner"
if dry; then skip "dry run"; else
  # owner = site user (PHP-FPM runs as it), group = www-data.
  for x in storage bootstrap/cache; do [[ -d $d/$x ]] || install -d -m 0755 "$d/$x"; done
  # An older deploy set the setgid bit here: it goes
  if [[ -g $d/storage ]]; then
    find "$d/storage" "$d/bootstrap/cache" -type d -exec chmod g-s {} +
    changed
  fi
  set_site_permissions "$d"
fi
