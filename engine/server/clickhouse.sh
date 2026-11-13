# server/clickhouse.sh - server part "clickhouse": ClickHouse server and client, pinned to
# $clickhouse_version and held (apt upgrade cannot change it), listening on 127.0.0.1 only, with a
# password for the "default" user (/etc/deployer/clickhouse_password). Runs on both setups (a host
# service). Skipped when up to date (steps/server-parts.sh).

clickhouse_version=26.7.5.10
deb_arch=$(dpkg --print-architecture)

task "Add the ClickHouse apt repository"
if dry && [[ ! -e /etc/apt/sources.list.d/clickhouse.list ]]; then changed; note "would add packages.clickhouse.com"
else
  install -d -m 0755 /etc/apt/keyrings
  if [[ ! -e /etc/apt/keyrings/clickhouse.gpg ]]; then
    fp=$(gpg --batch --show-keys --with-colons "$ENGINE_DIR/files/clickhouse.asc" 2>/dev/null | awk -F: '$1=="fpr" {print $10; exit}')
    [[ $fp == 3A9EA1193A97B548BE1457D48919F6BD2B48D754 ]] || fail "Bad GPG fingerprint for the ClickHouse repository: $fp"
    gpg --batch --yes --dearmor < "$ENGINE_DIR/files/clickhouse.asc" > /etc/apt/keyrings/clickhouse.gpg
    chmod 0644 /etc/apt/keyrings/clickhouse.gpg; changed
  fi
  put_template clickhouse.list.tpl /etc/apt/sources.list.d/clickhouse.list 0644 root root
  ((! PUT_CHANGED)) || dry || apt_update_if_old force
fi

task "Install ClickHouse $clickhouse_version and hold it"
ch_pkgs=(clickhouse-common-static clickhouse-client clickhouse-server)
have=$(dpkg-query -W -f='${Version}' clickhouse-server 2>/dev/null || true)
if [[ $have == "$clickhouse_version" ]]; then :
elif dry; then changed; note "would install ClickHouse $clickhouse_version${have:+ (now $have)}"
else
  apt-mark unhold "${ch_pkgs[@]}" >/dev/null 2>&1 || true
  apt_get install --allow-downgrades \
    "${ch_pkgs[@]/%/=$clickhouse_version}"
  changed
fi
dry || apt-mark hold "${ch_pkgs[@]}" >/dev/null

task "ClickHouse password for the default user" secret
# the password typed in deploy.sh (clickhouse_password), else a random one; kept on later runs
if [[ -n ${clickhouse_password:-} ]]; then
  dry || { printf '%s\n' "$clickhouse_password" | put_content /etc/deployer/clickhouse_password 0600 root root --secret; }
elif [[ ! -f /etc/deployer/clickhouse_password ]]; then
  changed
  dry || { openssl rand -hex 16 | put_content /etc/deployer/clickhouse_password 0600 root root --secret; }
fi
clickhouse_password_sha256=$( { tr -d '[:space:]' < /etc/deployer/clickhouse_password 2>/dev/null || true; } | sha256sum | cut -d' ' -f1)
put_template clickhouse-default-password.xml.tpl /etc/clickhouse-server/users.d/deployer-default-password.xml 0640 clickhouse clickhouse --secret
ch_changed=$PUT_CHANGED

task "ClickHouse listens on 127.0.0.1 only"
put_template clickhouse-listen.xml.tpl /etc/clickhouse-server/config.d/deployer-listen.xml 0640 clickhouse clickhouse
((! PUT_CHANGED)) || ch_changed=1

task "Restart ClickHouse automatically when it stops unexpectedly"
ensure_dir /etc/systemd/system/clickhouse-server.service.d 0755 root root
restart_label=ClickHouse put_template systemd-restart.conf.tpl /etc/systemd/system/clickhouse-server.service.d/deployer-restart.conf 0644 root root
if ((PUT_CHANGED)) && ! dry; then systemctl daemon-reload; fi

task "Restart clickhouse-server when its settings changed"
if ((ch_changed)) && ! dry && systemctl is-active --quiet clickhouse-server; then systemctl restart clickhouse-server; changed
else skip "unchanged"; fi
