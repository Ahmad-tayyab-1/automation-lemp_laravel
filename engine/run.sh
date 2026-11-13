#!/usr/bin/env bash
# engine/run.sh - the bash version of ansible/site.yml. Runs on the target as root:
#
#   bash engine/run.sh VARS_FILE
#
# VARS_FILE is written by deploy.sh (build_vars, or build_server_vars for "deploy.sh server": server
# parts only, no site): plain bash assignments for this deploy. The steps in
# steps/ run in the order below; server parts in server/ run only when needed (steps/server-parts.sh).
# Templates are in templates/*.tpl (see lib/template.sh), plain files in files/.

ENGINE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export LC_ALL=C.UTF-8 LANG=C.UTF-8
umask 022

# Nothing in the engine may wait for a person: no keyboard input (stdin is /dev/null, so a tool that
# asks a question gets "no answer" and goes on or fails, instead of hanging), no pagers, and every tool
# in its non-interactive mode (apt and dpkg keep changed config files, needrestart restarts services
# itself, Composer runs as root without asking, git never asks for a password).
exec </dev/null
export DEBIAN_FRONTEND=noninteractive DEBCONF_NONINTERACTIVE_SEEN=true UCF_FORCE_CONFFOLD=1 \
       NEEDRESTART_MODE=a NEEDRESTART_SUSPEND=1 APT_LISTCHANGES_FRONTEND=none \
       PAGER=cat GIT_PAGER=cat SYSTEMD_PAGER=cat SYSTEMD_LESS='' MANPAGER=cat \
       COMPOSER_ALLOW_SUPERUSER=1 COMPOSER_NO_INTERACTION=1 \
       GIT_TERMINAL_PROMPT=0 GIT_ASKPASS=/bin/false SSH_ASKPASS=/bin/false \
       npm_config_yes=true npm_config_fund=false npm_config_update_notifier=false

[[ $(id -u) -eq 0 ]] || { echo "engine/run.sh must run as root (deploy.sh starts it with sudo)" >&2; exit 2; }
[[ -f ${1:-} ]] || { echo "usage: run.sh VARS_FILE" >&2; exit 2; }

# vars.sh refers to files sent along with it as "$BUNDLE_DIR/files/..."
BUNDLE_DIR=$(cd "$(dirname "$1")" && pwd)
# shellcheck source=/dev/null
source "$1"

source "$ENGINE_DIR/lib/core.sh"
source "$ENGINE_DIR/lib/template.sh"
source "$ENGINE_DIR/lib/files.sh"

# A stalled download never hangs a deploy: curl and git over https give up after 2 minutes without
# data (curl also retries), git over ssh after 1 minute of a dead connection (GIT_SSH_COMMAND below)
printf 'connect-timeout = 20\nretry = 3\nspeed-limit = 1\nspeed-time = 120\n' > "$ENGINE_TMP/.curlrc"
export CURL_HOME=$ENGINE_TMP GIT_HTTP_LOW_SPEED_LIMIT=1 GIT_HTTP_LOW_SPEED_TIME=120

# ---------------------------------------------------------------- fixed settings (site.yml "vars")
sites_root=/var/www/html
project_dir=$sites_root/$site_domain
tls_dir=/etc/nginx/cert                 # <domain>/certificate.crt and privatekey.key
legacy_tls_dir=/etc/ssl/deployer        # older deploys; a site's certificate moves on its next deploy
# certbot --webroot writes challenge files here; every TLS vhost serves /.well-known/acme-challenge/ from
# it. Hidden folder, so it is never mistaken for a site (glob /var/www/html/* skips it).
acme_webroot=/var/www/html/.acme
# the vhost answers certbot's challenges only for a certbot certificate (issued now, or renewed by
# certbot later); a site with its own certificate does not get that location
acme_in_vhost=no
[[ ${tls_mode:-none} != certbot && ! -f /etc/letsencrypt/renewal/${site_domain:-none}.conf ]] || acme_in_vhost=yes
# docker_stack = /opt/docker-stack (files/docker-stack, see its SETUP.md and CHANGES.md)
stack_dir=/opt/docker-stack
stack_project=docker-stack              # compose project name = folder name, as with a manual "docker compose up -d"
stack_db_project=docker-stack-db
stack_php_image=enzipe/php-fpm:8.2-alpine
stack_nginx_image=enzipe/nginx:stable-alpine
stack_nginx_container=enzipe-nginx
stack_redis_container=enzipe-redis
stack_db_container=enzipe-mariadb
stack_socket_dir=/run/php-docker
stack_nginx_conf=$stack_dir/nginx/conf
# The previous docker setup; stopped (never deleted) when a server moves to docker-stack
legacy_stack_dir=/opt/php-stack
backup_max_bytes=524288000
# Per-site PHP container, named like site-docker.sh does (site id, "_" and "." -> "-")
site_container=${site_id//[_.]/-}-php
docker=no; [[ $setup_type != docker_stack ]] || docker=yes
ipv6_ok=no; [[ ! -e /proc/net/if_inet6 ]] || ipv6_ok=yes
site_names="$site_domain${site_aliases[*]:+ ${site_aliases[*]}}"
deploy_date=$(date +%F)
slug=${site_domain//./-}

# git settings (git itself runs as the site user, see steps/code.sh)
export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=safe.directory GIT_CONFIG_VALUE_0='*' \
       GIT_SSH_COMMAND="ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=20 -o ServerAliveInterval=15 -o ServerAliveCountMax=4"

# ---------------------------------------------------------------- the steps
# "deploy.sh firewall" (firewall_only=yes): the CSF firewall only
if [[ ${firewall_only:-no} == yes ]]; then
  say "${C_B}CSF firewall: $fw_action${C_OFF}$(dry && echo "  ${C_YEL}DRY RUN: nothing is changed${C_OFF}")"
  source "$ENGINE_DIR/steps/firewall.sh"
  task_end
  run_handlers
  task_end
  exit 0
fi

# "deploy.sh server" (server_only=yes): only the chosen server parts, no site
if [[ ${server_only:-no} == yes ]]; then
  say "${C_B}Set up the server ($setup_type): ${server_components[*]}${server_php_versions[*]:+ (PHP ${server_php_versions[*]})}${C_OFF}$(dry && echo "  ${C_YEL}DRY RUN: nothing is changed${C_OFF}")"
  [[ -v stack_remove ]] || stack_remove=()
  : "${db_swap:=}" "${db_swap_mode:=}" "${second_db_kind:=}" "${restore_snapshot:=}" "${snapshot_label:=}"
  switch_site_domains=() switch_site_users=() switch_site_envs=() dump_sites=()
  source "$ENGINE_DIR/steps/checks.sh"            # inputs, OS, setup marker, ports
  source "$ENGINE_DIR/steps/stack-change.sh"      # snapshot, stop what is no longer wanted, database swap
  [[ $switch_mode != stop ]] || source "$ENGINE_DIR/steps/switch-close.sh"   # a server without sites changes setup
  source "$ENGINE_DIR/steps/server-parts.sh"      # the chosen parts, skipped when up to date
  source "$ENGINE_DIR/steps/server-services.sh"   # enable and start them, list versions
  source "$ENGINE_DIR/steps/stack-change-after.sh"   # rollback: import the snapshot's dumps
  task_end
  run_handlers
  task_end
  exit 0
fi
server_only=no

say "${C_B}Deploy $site_domain ($setup_type, $deploy_env)${C_OFF}$(dry && echo "  ${C_YEL}DRY RUN: nothing is changed${C_OFF}")"

source "$ENGINE_DIR/steps/checks.sh"              # 1. inputs, OS, setup marker, ports and ownership
[[ $switch_mode != stop ]] || source "$ENGINE_DIR/steps/switch-close.sh"   # 2a. close the previous setup
source "$ENGINE_DIR/steps/server-parts.sh"        # 2. server parts, skipped when up to date
if [[ $setup_type == docker_stack ]]; then          # services running, passwords and commands
  source "$ENGINE_DIR/steps/runtime-docker.sh"
else
  source "$ENGINE_DIR/steps/runtime-native.sh"
fi
source "$ENGINE_DIR/steps/user.sh"                # 3. site user
[[ $tls_mode == none ]] || source "$ENGINE_DIR/steps/tls.sh"   # 4. certificates
source "$ENGINE_DIR/steps/code.sh"                # 5. git
source "$ENGINE_DIR/steps/redis-db.sh"            # 6. Redis databases
source "$ENGINE_DIR/steps/env.sh"                 #    .env
if [[ $setup_type == docker_stack ]]; then          # 7. PHP and nginx for the site
  source "$ENGINE_DIR/steps/web-docker.sh"
else
  source "$ENGINE_DIR/steps/web-native.sh"
fi
if [[ $tls_mode == certbot ]] && ! dry; then        # 7b. Let's Encrypt certificate
  source "$ENGINE_DIR/steps/certbot-issue.sh"
fi
[[ $deploy_env != local ]] || source "$ENGINE_DIR/steps/database.sh"   # 8. local database
source "$ENGINE_DIR/steps/laravel.sh"             # 9. composer, artisan, scheduler
source "$ENGINE_DIR/steps/verify.sh"              # 10. verify and record
task_end
run_handlers
task_end
