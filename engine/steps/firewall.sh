# steps/firewall.sh - "deploy.sh firewall" (firewall_only=yes): the CSF firewall (ConfigServer Security &
# Firewall, iptables rules) and LFD (its login failure daemon, blocks IPs that brute-force SSH).
#
#   fw_action      setup (install when missing, then configure), off (csf -x), on (csf -e), uninstall
#   fw_tcp_in      ports open to everyone, e.g. "22,80,443" (the SSH ports are added when fw_ssh_open=yes)
#   fw_udp_in      the same for UDP ("" = none)
#   fw_tcp_out     ports the server may connect to ("1:65535" = all), fw_udp_out the same for UDP
#   fw_ssh_open    yes: SSH open to everyone (LFD blocks brute force), no: only the fw_allow IPs
#   fw_cloudflare  yes: 80 and 443 only from Cloudflare's ranges (www.cloudflare.com/ips)
#   fw_allow       IPs always allowed, every port (csf.allow)    fw_ignore  IPs LFD never blocks (csf.ignore)
#   fw_deny        IPs always blocked (csf.deny)                 fw_port_rules  "PROTO|in|d=PORT|s=IP" (csf.allow)
#   fw_ping        1: answer ping, 0: no
#   fw_ssh_limit   failed SSH logins before LFD blocks the IP (0 = off), fw_ssh_block 1 (for good) or seconds
#   fw_alert_to    where LFD mails its alerts ("" = root on this server)
#   fw_testing     1: TESTING mode (csf clears its rules every 5 minutes, LFD does not run). deploy.sh
#                  first applies a change in TESTING mode, checks that a new SSH connection works, and
#                  only then switches TESTING off (fw_live in deploy.sh).
#
# The lists deploy.sh writes are kept between "# BEGIN deployer" and "# END deployer" in csf.allow,
# csf.ignore and csf.deny; lines added by hand (or by csf -a / csf -d) stay.

csf_urls=(https://download.configserver.com/csf.tgz https://download.configserver.dev/csf.tgz)
csf_conf=/etc/csf/csf.conf
csf_version() { csf -v 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g' | grep -oE 'v[0-9]+(\.[0-9]+)+' | head -n 1 || true; }

section "Checks"
task "Check operating system compatibility"
os_id=$(. /etc/os-release; echo "${ID:-}") os_version=$(. /etc/os-release; echo "${VERSION_ID:-}")
[[ $os_id == ubuntu && ($os_version == 22.04 || $os_version == 24.04) ]] || [[ $os_id == debian && ${os_version%%.*} == 12 ]] \
  || fail "Unsupported OS: $os_id $os_version."

task "Validate the firewall settings"
[[ $fw_action =~ ^(setup|off|on|uninstall)$ ]] || fail "Invalid firewall action '$fw_action' (setup, off, on, uninstall)."
ports_ok() {
  [[ -z $1 ]] && return 0
  [[ $1 =~ ^[0-9]+(:[0-9]+)?(,[0-9]+(:[0-9]+)?)*$ ]] || return 1
  local p a b
  for p in ${1//,/ }; do a=${p%%:*} b=${p##*:}; ((10#$a >= 1 && 10#$b <= 65535 && 10#$a <= 10#$b)) || return 1; done
}
if [[ $fw_action == setup ]]; then
  for v in "$fw_tcp_in" "$fw_udp_in" "$fw_tcp_out" "$fw_udp_out"; do ports_ok "$v" || fail "Invalid port list '$v' (e.g. 22,80,443 or 30000:30100)."; done
  [[ $fw_ssh_limit =~ ^[0-9]+$ && $fw_ssh_block =~ ^[0-9]+$ && $fw_ping =~ ^[01]$ && $fw_testing =~ ^[01]$ ]] || fail "Invalid LFD or ping settings."
  for r in "${fw_port_rules[@]}"; do
    [[ $r =~ ^(tcp|udp)\|in\|d=[0-9]+(_[0-9]+)?\|s=[0-9A-Fa-f.:/]+$ ]] || fail "Invalid port rule '$r' (PROTO|in|d=PORT|s=IP)."
  done
  # Everyone connected over SSH right now is always allowed (and never blocked): a change can never
  # cut off the session it runs in, whatever the lists say
  for ip in $(ss -Htnp state established 2>/dev/null | awk '/sshd/ {print $4}' | sed -E 's/:[0-9]+$//; s/^\[//; s/\]$//; s/^::ffff://' | sort -u || true); do
    [[ " ${fw_allow[*]} " == *" $ip "* ]] || { fw_allow+=("$ip"); note "allowed $ip: it is connected over SSH now"; }
    keep=(); for d in "${fw_deny[@]}"; do [[ $d == "$ip" ]] || keep+=("$d"); done; fw_deny=("${keep[@]}")
  done
  # the ports sshd listens on: never closed (fw_ssh_open=no: open to the fw_allow IPs only)
  ssh_ports=$(sshd -T 2>/dev/null | awk '$1 == "port" {print $2}' | sort -un | paste -sd, - || true)
  [[ -n $ssh_ports ]] || ssh_ports=22
  if [[ $fw_ssh_open == no ]]; then
    ((${#fw_allow[@]})) || fail "SSH only from the allowed IPs needs at least one allowed IP (or you are locked out)."
    for p in ${ssh_ports//,/ }; do fw_tcp_in=$(tr ',' '\n' <<< "$fw_tcp_in" | grep -vx "$p" | paste -sd, - || true); done
  else
    for p in ${ssh_ports//,/ }; do [[ ",$fw_tcp_in," == *",$p,"* ]] || fw_tcp_in=$p${fw_tcp_in:+,$fw_tcp_in}; done
  fi
  note "SSH port(s): $ssh_ports ($([[ $fw_ssh_open == no ]] && echo "only from the allowed IPs" || echo "open to everyone"))"
fi

# ---------------------------------------------------------------- off, on, uninstall
if [[ $fw_action != setup ]]; then
  section "CSF firewall"
  [[ -x /usr/sbin/csf ]] || { task "CSF"; skip "not installed"; task_end; return 0; }
  case $fw_action in
    off)
      task "Turn CSF and LFD off (csf -x: rules removed, both disabled)"
      if dry; then changed; note "would run csf -x"
      elif [[ -e /etc/csf/csf.disable ]]; then skip "already off"
      else csf -x || fail "csf -x failed"; changed; fi ;;
    on)
      task "Turn CSF and LFD on again (csf -e)"
      if dry; then changed; note "would run csf -e"
      elif [[ ! -e /etc/csf/csf.disable ]]; then skip "already on"
      else csf -e || fail "csf -e failed"; changed; fi ;;
    uninstall)
      task "Uninstall CSF and LFD (their settings in /etc/csf are removed)"
      if dry; then changed; note "would back up /etc/csf and run its uninstall.sh"
      else
        install -d -m 0755 /var/lib/deployer
        b=/var/lib/deployer/csf-before-uninstall-$(date +%Y%m%d-%H%M%S).tgz
        tar -C /etc -czf "$b" csf
        sh /etc/csf/uninstall.sh >/dev/null 2>&1 || true
        [[ ! -x /usr/sbin/csf ]] || fail "The CSF uninstaller did not remove /usr/sbin/csf"
        note "A copy of /etc/csf is in $b"
        changed
      fi ;;
  esac
  # csf removed its rules (and Docker's): Docker creates its own again
  if ! dry && [[ $fw_action != on ]] && { systemctl is-active --quiet docker || systemctl is-failed --quiet docker; }; then
    task "Restart Docker (it creates its iptables rules again)"
    systemctl reset-failed docker.service docker.socket >/dev/null 2>&1 || true
    systemctl restart docker || fail "Docker did not start: $(systemctl status docker --no-pager -n 8 2>&1)"
    changed
  fi
  task_end
  return 0
fi

# ---------------------------------------------------------------- install
section "CSF firewall: install"

task "Turn off ufw and firewalld (only one firewall may manage iptables)"
for u in ufw firewalld; do
  systemctl is-active --quiet "$u" 2>/dev/null || systemctl is-enabled --quiet "$u" 2>/dev/null || continue
  changed
  if dry; then note "would stop and disable $u"; continue; fi
  [[ $u != ufw ]] || ufw --force disable >/dev/null 2>&1 || true
  systemctl disable --now "$u" >/dev/null 2>&1 || true
  note "$u stopped and disabled"
done

task "Install the packages CSF needs (perl modules, iptables, ipset)"
apt_install perl libwww-perl liblwp-protocol-https-perl libio-socket-ssl-perl libcrypt-ssleay-perl \
  libnet-libidn-perl libio-socket-inet6-perl libsocket6-perl iptables ipset unzip wget curl

task "Download and install CSF"
if [[ -x /usr/sbin/csf ]]; then
  skip "installed: CSF $(csf_version)"
elif dry; then changed; note "would download csf.tgz and run its install.sh"
else
  d=$ENGINE_TMP/csf-src; rm -rf "$d"; mkdir -p "$d"
  got=''
  for u in "${csf_urls[@]}"; do
    if curl -fsSL --max-time 300 -o "$d/csf.tgz" "$u" && tar -tzf "$d/csf.tgz" csf/install.sh >/dev/null 2>&1; then got=$u; break; fi
    note "could not download $u"
  done
  [[ -n $got ]] || fail "CSF could not be downloaded from ${csf_urls[*]}"
  tar -xzf "$d/csf.tgz" -C "$d"
  (cd "$d/csf" && sh install.sh) > "$d/install.log" 2>&1 || fail "The CSF installer failed: $(tail -n 15 "$d/install.log")"
  [[ -x /usr/sbin/csf ]] || fail "The CSF installer did not install /usr/sbin/csf: $(tail -n 15 "$d/install.log")"
  note "installed CSF $(csf_version) from $got"
  changed
fi

task "Check that iptables has what CSF needs (csftest.pl)"
if dry && [[ ! -x /usr/sbin/csf ]]; then skip "dry run"
else
  out=$(perl /usr/local/csf/bin/csftest.pl 2>&1 || true)
  [[ $out == *"csf should function on this server"* ]] || fail "csftest.pl: CSF cannot work on this server: $(tail -n 8 <<< "$out")"
fi

# A dry run on a server without CSF stops here (there is no csf.conf to compare with yet)
if dry && [[ ! -f $csf_conf ]]; then
  note "Dry run: a real run installs CSF first; its settings are shown after that."
  task_end; return 0
fi

# ---------------------------------------------------------------- configure
section "CSF firewall: settings"

task "Keep a copy of the CSF settings"
if ! dry; then
  install -d -m 0700 /var/lib/deployer/csf-backups
  b=/var/lib/deployer/csf-backups/$(date +%Y%m%d-%H%M%S).tgz
  tar -C /etc -czf "$b" csf
  ls -1t /var/lib/deployer/csf-backups/*.tgz | tail -n +21 | xargs -r rm -f   # the newest 20
  note "$b"
fi

# Cloudflare: 80 and 443 only from its ranges
cf_rules=()
if [[ $fw_cloudflare == yes ]]; then
  task "Read Cloudflare's IP ranges"
  cf=$(curl -fsSL --max-time 30 https://www.cloudflare.com/ips-v4; echo; curl -fsSL --max-time 30 https://www.cloudflare.com/ips-v6) \
    || fail "Cloudflare's IP ranges could not be read from www.cloudflare.com/ips-v4 and ips-v6"
  n=0
  while read -r r; do
    [[ $r =~ ^[0-9A-Fa-f.:]+/[0-9]+$ ]] || continue
    cf_rules+=("tcp|in|d=80|s=$r" "tcp|in|d=443|s=$r"); n=$((n + 1))
  done <<< "$cf"
  ((n > 5)) || fail "Cloudflare's IP list looks wrong ($n ranges)"
  note "$n ranges"
  fw_tcp_in=$(tr ',' '\n' <<< "$fw_tcp_in" | grep -vx -e 80 -e 443 | paste -sd, - || true)
fi

ipv6=0
if ip -6 route show default 2>/dev/null | grep -q . && command -v ip6tables >/dev/null 2>&1; then ipv6=1; fi

# csf_set KEY VALUE: KEY = "VALUE" in csf.conf
csf_set() { line_in_file "$csf_conf" "^$1 *=" "$1 = \"$2\""; }
task "Write the settings to $csf_conf"
dry || csf_set TESTING "$fw_testing"   # a dry run shows the settings, not the TESTING step of the change
csf_set TCP_IN "$fw_tcp_in"
csf_set UDP_IN "$fw_udp_in"
csf_set TCP_OUT "$fw_tcp_out"
csf_set UDP_OUT "$fw_udp_out"
csf_set IPV6 "$ipv6"
if ((ipv6)); then
  csf_set TCP6_IN "$fw_tcp_in"; csf_set UDP6_IN "$fw_udp_in"
  csf_set TCP6_OUT "$fw_tcp_out"; csf_set UDP6_OUT "$fw_udp_out"
fi
csf_set ICMP_IN "$fw_ping"
csf_set RESTRICT_SYSLOG 3             # LFD reads the logs; only root and the syslog user may write them
csf_set LF_SSHD "$fw_ssh_limit"
csf_set LF_SSHD_PERM "$fw_ssh_block"
csf_set LF_ALERT_TO "$fw_alert_to"
# CSF's own Docker rules only cover docker0; the csfpost.sh hook below restarts Docker instead
csf_set DOCKER 0
note "open: TCP ${fw_tcp_in:-none}; UDP ${fw_udp_in:-none}$( ((ipv6)) && echo "; IPv6 the same")"

# fw_block FILE TITLE LINE...: the deployer block in FILE holds exactly LINE...
fw_block() {
  local file=$1 fw_block_title=$2; shift 2
  local fw_block_lines=("$@") out=$ENGINE_TMP/fw-block
  { [[ ! -f $file ]] || sed '/^# BEGIN deployer/,/^# END deployer/d' "$file"
    ((${#fw_block_lines[@]} == 0)) || tpl_render csf-block.tpl
  } > "$out" || fail "Could not write the deployer block of $file"
  put_content "$file" 0600 root root < "$out"
}
task "Always allowed: csf.allow (${#fw_allow[@]} IP(s), ${#fw_port_rules[@]} port rule(s)$([[ $fw_cloudflare == yes ]] && echo ", Cloudflare on 80/443"))"
allow_lines=(); for ip in "${fw_allow[@]}"; do allow_lines+=("$ip # deploy.sh firewall"); done
allow_lines+=("${fw_port_rules[@]}" "${cf_rules[@]}")
if [[ $fw_ssh_open == no ]]; then
  # every allowed IP reaches every port anyway; written for the record
  for ip in "${fw_allow[@]}"; do for p in ${ssh_ports//,/ }; do allow_lines+=("tcp|in|d=$p|s=$ip"); done; done
fi
fw_block /etc/csf/csf.allow "allowed IPs and port rules" "${allow_lines[@]}"

task "Never blocked by LFD: csf.ignore (${#fw_ignore[@]} IP(s))"
fw_block /etc/csf/csf.ignore "IPs that LFD never blocks" "${fw_ignore[@]}"

task "Always blocked: csf.deny (${#fw_deny[@]} IP(s))"
deny_lines=(); for ip in "${fw_deny[@]}"; do deny_lines+=("$ip # deploy.sh firewall"); done
fw_block /etc/csf/csf.deny "IPs that are always blocked" "${deny_lines[@]}"

# Docker: csf flushes its rules; the hook restarts Docker after csf, live-restore keeps the containers up
if command -v dockerd >/dev/null 2>&1; then
  task "Docker: keep containers running when Docker restarts (live-restore)"
  dj=/etc/docker/daemon.json
  command -v jq >/dev/null 2>&1 || apt_install jq
  cur='{}'; [[ ! -s $dj ]] || cur=$(jq -c . "$dj" 2>/dev/null) || fail "$dj is not valid JSON"
  if [[ $(jq -r '."live-restore" // false' <<< "$cur") != true ]]; then
    ensure_dir /etc/docker 0755 root root
    jq --indent 4 '. + {"live-restore": true}' <<< "$cur" | put_content "$dj" 0644 root root --backup
    dry || ! systemctl is-active --quiet docker || systemctl reload docker   # live-restore is reloadable
  fi

  task "Docker: create its iptables rules again after csf (/etc/csf/csfpost.sh)"
  if [[ -f /etc/csf/csfpost.sh ]] && ! grep -q 'managed by deployer' /etc/csf/csfpost.sh; then
    if grep -q 'systemctl restart docker' /etc/csf/csfpost.sh; then skip "already in /etc/csf/csfpost.sh"
    else fail "/etc/csf/csfpost.sh exists and was not written by the deployer. Add 'systemctl is-active --quiet docker && systemctl restart docker' to it, then run again."; fi
  else
    put_template csfpost.sh.tpl /etc/csf/csfpost.sh 0700 root root
  fi
fi

# ---------------------------------------------------------------- start
section "CSF firewall: start"

task "Load the rules (csf -r) and enable CSF at boot"
if dry; then skip "dry run"
else
  [[ ! -e /etc/csf/csf.disable ]] || { csf -e >/dev/null 2>&1 || true; }
  # csf -r, never "systemctl restart csf": with FASTSTART its stop saves the rules that are loaded and
  # its start loads them back, so the new settings would not be applied
  out=$(csf -r 2>&1) || fail "csf -r failed: $(sed 's/\x1b\[[0-9;]*m//g' <<< "$out" | tail -n 15)"
  # csf -r exits 0 even when iptables refused a rule and nothing was loaded (the server is then open)
  iptables -nL LOCALINPUT >/dev/null 2>&1 \
    || fail "csf -r did not load the rules (the server has no firewall now): $(sed 's/\x1b\[[0-9;]*m//g' <<< "$out" | grep -iE 'error|invalid|fail' | tail -n 8)"
  systemctl is-enabled --quiet csf || systemctl enable --quiet csf
  changed
fi

# csfpost.sh restarts Docker after every csf reload; it must be running again afterwards
if command -v dockerd >/dev/null 2>&1 && ! dry && { systemctl is-enabled --quiet docker 2>/dev/null || systemctl is-failed --quiet docker; }; then
  task "Docker runs again after csf (its iptables rules created again)"
  if ! systemctl is-active --quiet docker; then
    systemctl reset-failed docker.service docker.socket >/dev/null 2>&1 || true
    systemctl start docker || fail "Docker did not start after csf: $(systemctl status docker --no-pager -n 8 2>&1)"
    changed
  fi
fi

task "LFD (blocks IPs after failed logins)"
if dry; then skip "dry run"
elif ((fw_testing)); then
  systemctl stop lfd >/dev/null 2>&1 || true
  skip "not running in TESTING mode"
else
  systemctl enable --quiet lfd
  systemctl restart lfd || fail "lfd did not start: $(systemctl status lfd --no-pager -n 8 2>&1)"
  changed
fi

task "Firewall state"
if dry; then skip "dry run"
else
  note "CSF $(csf_version), $( ((fw_testing)) && echo "TESTING mode (its rules are cleared every 5 minutes)" || echo "live"), LFD $( ((fw_testing)) && echo "off until TESTING ends" || systemctl is-active lfd 2>/dev/null || true)"
  note "open to everyone: TCP ${fw_tcp_in:-none}, UDP ${fw_udp_in:-none}; outgoing TCP $([[ $fw_tcp_out == 1:65535 ]] && echo all || echo "$fw_tcp_out")"
  listen=$(ss -Hltn 2>/dev/null | awk '{print $4}' | grep -vE '^(127\.|\[::1\]|\[::ffff:127\.)' | sed 's/.*://' | sort -un | paste -sd, - || true)
  pub=''
  if command -v docker >/dev/null 2>&1 && [[ -n $(docker ps -q 2>/dev/null) ]]; then
    pub=$(docker ps --format '{{.Ports}}' | tr ',' '\n' | grep -oE '^ *(0\.0\.0\.0|\[::\]|:::)?:?[0-9]+->' | grep -oE '[0-9]+->' | tr -d '>-' | sort -un | paste -sd, - || true)
  fi
  closed=$(for p in ${listen//,/ }; do [[ ",$fw_tcp_in,$pub," == *",$p,"* ]] || echo "$p"; done | paste -sd, - || true)
  [[ -z $closed ]] || note "listening but closed to the public now: TCP $closed (still open to the allowed IPs)"
  [[ -z $pub ]] || note "open anyway: TCP $pub, published by Docker containers (Docker's rules come before csf's port lists)"
fi
task_end
