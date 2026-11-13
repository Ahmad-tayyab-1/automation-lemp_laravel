# steps/user.sh - the site's Linux user: a real account (/home/<user>, bash). It owns
# the project folder and holds the git key in ~/.ssh/id_rsa and id_rsa.pub, so only it can reach the repo.
# One user per site, or one for all the server's sites (site_user_mode, saved in /etc/deployer/site_user).

section "Site user"

task "Ensure the site's Linux group and user exist"
comment=deployer-managed-$site_domain site_home=/home/$linux_user
[[ $site_user_mode != shared ]] || comment=deployer-managed-all-sites
if e=$(getent passwd "$linux_user"); then
  [[ $site_user_mode != shared ]] || (( $(cut -d: -f3 <<< "$e") >= 1000 )) \
    || fail "'$linux_user' is a system account. Choose another name for the user of all sites."
  case $(cut -d: -f5 <<< "$e") in
    "deployer-managed-$site_domain"|"deployer-managed=$site_domain"|"deployer-managed:$site_domain")
      if ! getent group "$linux_user" >/dev/null; then changed; dry || groupadd "$linux_user"; fi
      gid=$(getent group "$linux_user" | cut -d: -f3 || true)
      if [[ $(cut -d: -f4-7 <<< "$e") != "$gid:$comment:$site_home:/bin/bash" ]]; then
        changed
        dry || usermod -g "$linux_user" -c "$comment" -d "$site_home" -s /bin/bash "$linux_user"
        # The home used to be the project folder: the caches composer left there go (not if git tracks them)
        if ! dry && [[ $(cut -d: -f6 <<< "$e") == "$project_dir" ]]; then
          for x in .cache .config .local .composer .npm .gitconfig; do
            [[ -e $project_dir/$x ]] || continue
            [[ -z $(git -C "$project_dir" ls-files -- "$x" 2>/dev/null) ]] || continue
            rm -rf "${project_dir:?}/$x"
          done
        fi
      fi ;;
    *) # an account made by hand: used as it is, with its own home and shell
      site_home=$(cut -d: -f6 <<< "$e") ;;
  esac
else
  if ! getent group "$linux_user" >/dev/null; then changed; dry || groupadd "$linux_user"; fi
  changed; dry || useradd -g "$linux_user" -c "$comment" -d "$site_home" -m -s /bin/bash "$linux_user"
fi
if ! dry; then
  if [[ ! -d $site_home ]]; then
    changed
    install -d -m 0750 -o "$linux_user" -g "$(id -gn "$linux_user")" "$site_home"
    cp -rT /etc/skel "$site_home"
    chown -R "$linux_user:$(id -gn "$linux_user")" "$site_home"
  fi
fi
# A dry run of a new site has no user yet: 1000 stands in for the numbers
site_uid=$(id -u "$linux_user" 2>/dev/null || echo 1000)
site_gid=$(id -g "$linux_user" 2>/dev/null || echo 1000)
site_group=$(id -gn "$linux_user" 2>/dev/null || echo "$linux_user")

task "Remember how this server's sites get their users"
want=$linux_user; [[ $site_user_mode != per_site ]] || want=per_site
if [[ $(cat /etc/deployer/site_user 2>/dev/null || true) != "$want" ]]; then
  changed
  if ! dry; then install -d -m 0755 /etc/deployer; printf '%s\n' "$want" > /etc/deployer/site_user; fi
fi

if [[ $site_repo =~ ^(git@|ssh://) ]]; then
  task "The site user's git key (~/.ssh/id_rsa and id_rsa.pub)" secret
  if [[ -n $site_key_file ]]; then
    if dry; then note "would install the git key in $site_home/.ssh/"; changed; else
      if [[ $site_user_mode == shared && -f $site_home/.ssh/id_rsa ]] && ! cmp -s "$site_key_file" "$site_home/.ssh/id_rsa"; then
        note "WARNING: this replaces $linux_user's git key. The other sites' repositories must accept the new key."
      fi
      ensure_dir "$site_home/.ssh" 0700 "$linux_user" "$site_group"
      put_content "$site_home/.ssh/id_rsa" 0600 "$linux_user" "$site_group" --secret < "$site_key_file"
      put_content "$site_home/.ssh/id_rsa.pub" 0644 "$linux_user" "$site_group" < "$site_pub_file"
    fi
  elif [[ ! -f $site_home/.ssh/id_rsa ]]; then
    dry || fail "$linux_user has no git key in $site_home/.ssh/id_rsa. Add it with: deploy.sh add-site $site_domain"
    note "a real run stops here: $linux_user has no git key yet"
  fi
fi
