# server/certbot.sh - server part "certbot": certbot (webroot mode only), its renewal timer, the ACME
# webroot and the deploy hook that hands renewed certificates to nginx. Installed with the first
# certbot site. Skipped when up to date (steps/server-parts.sh).

task "Install certbot (webroot mode only; the nginx plugin is never used)"
command -v certbot >/dev/null 2>&1 || apt_install certbot

task "Enable the certbot renewal timer"
if dry; then skip "dry run"
elif systemctl list-unit-files certbot.timer --no-legend 2>/dev/null | grep -q '^certbot.timer'; then
  systemctl is-enabled --quiet certbot.timer && systemctl is-active --quiet certbot.timer || { systemctl enable --now certbot.timer; changed; }
fi

task "Ensure the ACME challenge webroot and the certbot hook folder exist"
ensure_dir "$acme_webroot" 0755 root root
ensure_dir /etc/letsencrypt/renewal-hooks/deploy 0755 root root

task "Install the certbot deploy hook that hands renewed certificates to nginx"
put_template certbot-deploy-hook.sh.tpl /etc/letsencrypt/renewal-hooks/deploy/deployer-nginx.sh 0755 root root
