# steps/tls.sh - certificates (tls_mode is not "none"). nginx always reads /etc/nginx/cert/<domain>/
# certificate.crt and privatekey.key. tls_mode only decides how they get there:
#   files     copied from the deploy machine (certificate files, or a certificate pasted in the terminal)
#   existing  copied from other paths on the target (nothing to copy when they are already in place)
#   certbot   Let's Encrypt with "certbot certonly --webroot" (steps/certbot-issue.sh). certbot never
#             edits nginx files. certbot itself is the server part server/certbot.sh.

section "Certificates"
cert_dir=$tls_dir/$site_domain cert_crt=$cert_dir/certificate.crt cert_key=$cert_dir/privatekey.key
legacy_dir=$legacy_tls_dir/$site_domain

# tls_install CERT KEY: copies a certificate pair (symlinks followed) into the site's folder
tls_install() {
  put_content "$cert_crt" 0644 root root < "$1"
  put_content "$cert_key" 0600 root root --secret < "$2"
}

task "Ensure the target certificate folder exists"
ensure_dir "$tls_dir" 0755 root root
ensure_dir "$cert_dir" 0755 root root

# A certificate from an older deploy moves to the new folder. verify.sh removes the old copy once the
# site answers with the new vhost.
if [[ -e $legacy_dir/fullchain.pem && ! -e $cert_crt ]]; then
  task "Copy the certificate from $legacy_dir to $cert_dir" secret
  if dry; then
    changed; note "would copy the certificate to $cert_dir"
    [[ $tls_cert_path != "$cert_crt" ]] || { tls_cert_path=$legacy_dir/fullchain.pem tls_key_path=$legacy_dir/privkey.pem; }
  else
    tls_install "$legacy_dir/fullchain.pem" "$legacy_dir/privkey.pem"
    [[ ! -e $legacy_dir/.certbot ]] || install -m 0644 -o root -g root /dev/null "$cert_dir/.certbot"
  fi
fi
# A path saved by an older deploy means the new folder now
if ! dry || [[ -e $cert_crt ]]; then
  [[ $tls_cert_path != "$legacy_dir/fullchain.pem" ]] || tls_cert_path=$cert_crt
  [[ $tls_key_path != "$legacy_dir/privkey.pem" ]] || tls_key_path=$cert_key
fi

case $tls_mode in
  files)
    # deploy.sh sent the files along (bundle/tls/ on a remote target, the local paths otherwise)
    task "Install the certificate from the deploy machine" secret
    tls_install "$cert_file" "$key_file" ;;
  existing)
    task "Check that the certificate on the target is valid, not expired, and matches the key"
    [[ -e $tls_cert_path && -e $tls_key_path ]] || fail "Certificate or key not found on target ($tls_cert_path, $tls_key_path)."
    openssl x509 -in "$tls_cert_path" -noout -checkend 0 >/dev/null 2>&1 \
      || fail "Certificate $tls_cert_path is expired or not a PEM certificate"
    c=$(openssl x509 -in "$tls_cert_path" -noout -pubkey 2>/dev/null | openssl pkey -pubin -outform DER 2>/dev/null | sha256sum || true)
    k=$(openssl pkey -passin pass: -in "$tls_key_path" -pubout -outform DER 2>/dev/null | sha256sum || true)
    [[ $c == "$k" ]] || fail "Certificate $tls_cert_path does not match key $tls_key_path (or the key is not an unencrypted PEM key)"

    task "Copy the certificate into the deployer TLS folder for nginx" secret
    tls_install "$tls_cert_path" "$tls_key_path" ;;
esac

if [[ $tls_mode == files || $tls_mode == existing ]]; then
  task "Remove the certbot marker (the site uses another certificate source)"
  if [[ -e $cert_dir/.certbot ]]; then changed; dry || rm -f "$cert_dir/.certbot"; fi
fi

if [[ $tls_mode == certbot ]]; then
  task "Mark this site's certificate as managed by certbot"
  if [[ ! -e $cert_dir/.certbot ]]; then changed; dry || install -m 0644 -o root -g root /dev/null "$cert_dir/.certbot"; fi

  task "Copy the issued Let's Encrypt certificate for nginx" secret
  if [[ -e /etc/letsencrypt/live/$site_domain/fullchain.pem ]]; then
    tls_install "/etc/letsencrypt/live/$site_domain/fullchain.pem" "/etc/letsencrypt/live/$site_domain/privkey.pem"
  elif [[ -e $cert_crt ]]; then
    skip "not issued yet, the current certificate stays"
  else
    # First deploy: nginx needs some certificate to start, and nginx must run so certbot can answer
    # the challenge on port 80. Step 7b replaces this with the real certificate.
    changed
    if dry; then note "would create a temporary self-signed certificate"; else
      openssl req -x509 -nodes -newkey rsa:2048 -days 7 -subj "/CN=$site_domain" \
        -keyout "$cert_key" -out "$cert_crt" 2>/dev/null
      chmod 0600 "$cert_key"; chmod 0644 "$cert_crt"
      note "temporary self-signed certificate until certbot runs"
    fi
  fi
fi
