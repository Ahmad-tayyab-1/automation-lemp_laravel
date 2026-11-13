# steps/verify.sh - verify the site answers on this server, then record it in
# /etc/deployer/sites/<domain>.json (templates/site-record.json.tpl).

section "Verify"

task "Verify the site answers and record it on the target"
if dry; then skip "dry run"; else
  req() {
    if [[ $tls_mode != none ]]; then
      curl -k -s -o /dev/null -w '%{http_code}' --resolve "$site_domain:443:127.0.0.1" "https://$site_domain/"
    else
      curl -s -o /dev/null -w '%{http_code}' -H "Host: $site_domain" http://127.0.0.1/
    fi
  }
  i=0
  until code=$(req || true); [[ $code =~ ^(200|301|302|401)$ ]]; do
    i=$((i + 1))
    ((i < 10)) || fail "Site verification failed (HTTP ${code:-N/A}). Logs: $(verify_dump)"
    sleep 3
  done
  note "HTTP $code"
  # The site now reads its certificate from the new folder: the copy in the old one goes
  if [[ -d $legacy_tls_dir/$site_domain ]]; then rm -rf "${legacy_tls_dir:?}/$site_domain"; changed; fi
  site_aliases_json=$(if ((${#site_aliases[@]})); then printf '%s\n' "${site_aliases[@]}" | jq -Rnc '[inputs]'; else echo '[]'; fi)
  record_tls_mode=keep; [[ $tls_mode != none ]] || record_tls_mode=none
  ensure_dir /etc/deployer/sites 0755 root root
  put_template site-record.json.tpl "/etc/deployer/sites/$site_domain.json" 0644 root root
  changed
fi
