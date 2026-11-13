# server/native-nginx.sh - server part "native-nginx": nginx for native_lemp, with the Cloudflare real
# visitor IP settings and a systemd restart drop-in. Skipped when up to date (steps/server-parts.sh).
# Starting it happens on every deploy (steps/runtime-native.sh) or in steps/server-services.sh.

task "Install nginx"
apt_install nginx

# Cloudflare sends the visitor's address in CF-Connecting-IP; nginx logs and PHP's REMOTE_ADDR use it
# only for requests that really come from Cloudflare's ranges (anyone else cannot fake it).
# The ranges are the same as in the docker stack's nginx.conf.
task "Cloudflare real visitor IP for nginx (conf.d/deployer-realip.conf)"
put_template native-realip.conf.tpl /etc/nginx/conf.d/deployer-realip.conf 0644 root root
realip_changed=$PUT_CHANGED

# Fail-safe: nginx is restarted by systemd when it crashes or is killed (Ubuntu's unit does not)
task "Restart nginx automatically when it stops unexpectedly"
ensure_dir /etc/systemd/system/nginx.service.d 0755 root root
restart_label=nginx put_template systemd-restart.conf.tpl /etc/systemd/system/nginx.service.d/deployer-restart.conf 0644 root root
if ((PUT_CHANGED)) && ! dry; then systemctl daemon-reload; fi

# e.g. another config on the server already sets real_ip_header: keep nginx working without ours
task "Validate nginx with the real IP settings"
if ((realip_changed)) && ! dry; then
  if ! out=$(nginx -t 2>&1); then
    rm -f /etc/nginx/conf.d/deployer-realip.conf
    changed
    note "WARNING: nginx rejected conf.d/deployer-realip.conf, so it was removed again (visitor IPs behind Cloudflare stay Cloudflare's): $out"
  fi
else
  skip "unchanged"
fi
