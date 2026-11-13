# steps/certbot-issue.sh - Let's Encrypt certificate. "certbot certonly --webroot" only drops a challenge
# file into the ACME webroot (served by the vhost on port 80) and writes certificate files under
# /etc/letsencrypt. It never reads or edits nginx configs (no --nginx plugin), so the vhost from our
# template stays as it is.

section "Let's Encrypt certificate"

task "Request or renew the certificate (certonly --webroot, never edits nginx files)"
args=(certonly --webroot -w "$acme_webroot" --cert-name "$site_domain" --non-interactive --agree-tos)
# --force-renewal only when the renewal config still says "nginx": a new certificate rewrites it to
# webroot, so later automatic renewals cannot touch nginx files either.
if grep -Eq '^(authenticator|installer)[[:space:]]*=[[:space:]]*nginx' "/etc/letsencrypt/renewal/$site_domain.conf" 2>/dev/null; then
  args+=(--force-renewal)
else
  args+=(--keep-until-expiring)
fi
if [[ -n $certbot_email ]]; then args+=(-m "$certbot_email"); else args+=(--register-unsafely-without-email); fi
for n in $site_names; do args+=("--domains=$n"); done
if ! out=$(certbot "${args[@]}" 2>&1); then
  fail "certbot could not get a certificate for ${site_names// /, }. Check that DNS for each name points to this server and that port 80 is reachable from the internet. If the domain is proxied by Cloudflare, use option 2 (Cloudflare Origin Certificate) instead, or turn the proxy off while issuing. The site keeps its current certificate (a temporary self-signed one on a first deploy). certbot said: $(tail -c 1500 <<< "$out")"
fi
case $out in *'Successfully received certificate'*|*Congratulations*) changed ;; esac

task "Copy the Let's Encrypt certificate for nginx and reload it" secret
put_content "$tls_dir/$site_domain/certificate.crt" 0644 root root < "/etc/letsencrypt/live/$site_domain/fullchain.pem"
c1=$PUT_CHANGED
put_content "$tls_dir/$site_domain/privatekey.key" 0600 root root --secret < "/etc/letsencrypt/live/$site_domain/privkey.pem"
if ((c1 || PUT_CHANGED)); then
  if [[ $setup_type == native_lemp ]]; then nginx -t && systemctl reload nginx
  else docker exec "$stack_nginx_container" nginx -t && docker exec "$stack_nginx_container" nginx -s reload; fi
fi
