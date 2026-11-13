# server/node.sh - server part "node": Node.js $node_major LTS and npm from the NodeSource repository.
# Only the runtime (no process manager). Runs on both setups. Skipped when up to date
# (steps/server-parts.sh).

node_major=22

task "Add the NodeSource apt repository (Node $node_major.x)"
if dry && [[ ! -e /etc/apt/sources.list.d/nodesource.list ]]; then changed; note "would add deb.nodesource.com node_$node_major.x"
else
  install -d -m 0755 /etc/apt/keyrings
  if [[ ! -e /etc/apt/keyrings/nodesource.gpg ]]; then
    fp=$(gpg --batch --show-keys --with-colons "$ENGINE_DIR/files/nodesource.asc" 2>/dev/null | awk -F: '$1=="fpr" {print $10; exit}')
    [[ $fp == 6F71F525282841EEDAF851B42F59B5F99B1BE0B4 ]] || fail "Bad GPG fingerprint for the NodeSource repository: $fp"
    gpg --batch --yes --dearmor < "$ENGINE_DIR/files/nodesource.asc" > /etc/apt/keyrings/nodesource.gpg
    chmod 0644 /etc/apt/keyrings/nodesource.gpg; changed
  fi
  put_template nodesource.list.tpl /etc/apt/sources.list.d/nodesource.list 0644 root root
  ((! PUT_CHANGED)) || dry || apt_update_if_old force
fi

task "Install Node.js $node_major and npm"
if [[ $(node -v 2>/dev/null) == v$node_major.* ]]; then :
elif dry; then changed; note "would install nodejs $node_major.x"
else
  apt_get install nodejs
  [[ $(node -v 2>/dev/null) == v$node_major.* ]] || fail "nodejs installed, but node -v says '$(node -v 2>&1)', expected v$node_major"
  changed
fi
