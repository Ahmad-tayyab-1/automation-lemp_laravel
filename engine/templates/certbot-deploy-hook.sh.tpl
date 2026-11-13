#!/bin/sh
# managed by deployer
# Runs after certbot renews a certificate. For deployer sites that use certbot (marked with
# {{ tls_dir }}/<name>/.certbot) it copies the certificate to {{ tls_dir }}/<name>/ and reloads nginx.
# A site not deployed since the certificates moved still uses {{ legacy_tls_dir }}/<name>/.
# Certificates are obtained with "certonly --webroot", so certbot itself never edits nginx files.
set -e
name=$(basename "$RENEWED_LINEAGE")
dest="{{ tls_dir }}/$name" crt=certificate.crt key=privatekey.key
if [ ! -f "$dest/.certbot" ]; then
  dest="{{ legacy_tls_dir }}/$name" crt=fullchain.pem key=privkey.pem
fi
[ -f "$dest/.certbot" ] || exit 0
install -m 0644 -o root -g root "$RENEWED_LINEAGE/fullchain.pem" "$dest/$crt"
install -m 0600 -o root -g root "$RENEWED_LINEAGE/privkey.pem" "$dest/$key"
if [ "$(head -n 1 /etc/deployer/setup 2>/dev/null)" = "docker_stack" ]; then
  docker exec {{ stack_nginx_container }} nginx -t -q && docker exec {{ stack_nginx_container }} nginx -s reload
else
  nginx -t -q && systemctl reload nginx
fi
