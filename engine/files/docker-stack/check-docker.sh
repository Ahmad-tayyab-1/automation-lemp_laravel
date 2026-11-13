#!/usr/bin/env bash
# check-docker.sh — verifies that the Docker installation on this server is
# complete and ready for the shared stack. Read-only: it changes nothing.
#
#   bash /opt/docker-stack/check-docker.sh
#
# Exit code 0 = everything required passed, 1 = at least one required check failed.
# Warnings do not fail the run; they are things to look at, not blockers.

# No `set -e`: a failing check must not stop the rest of the report.
set -u

PASS=0; FAIL=0; WARN=0

G=''; R=''; Y=''; B=''; N=''
if [ -t 1 ]; then G=$'\033[32m'; R=$'\033[31m'; Y=$'\033[33m'; B=$'\033[1m'; N=$'\033[0m'; fi

ok()   { printf '  %s[ OK ]%s   %s\n'   "$G" "$N" "$1"; PASS=$((PASS+1)); }
bad()  { printf '  %s[FAIL]%s   %s\n'   "$R" "$N" "$1"; FAIL=$((FAIL+1));
         [ $# -gt 1 ] && printf '            fix: %s\n' "$2"; return 0; }
warn() { printf '  %s[WARN]%s   %s\n'   "$Y" "$N" "$1"; WARN=$((WARN+1));
         [ $# -gt 1 ] && printf '            %s\n' "$2"; return 0; }
head_() { printf '\n%s%s%s\n' "$B" "$1" "$N"; }

printf '\n%sDocker installation check — %s — %s%s\n' \
       "$B" "$(hostname)" "$(date '+%Y-%m-%d %H:%M')" "$N"

# ---------------------------------------------------------------- 1. binaries
head_ '1. Packages'

if command -v docker >/dev/null 2>&1; then
    ok "docker is installed  ($(docker --version 2>/dev/null | cut -d, -f1))"
else
    bad "docker is not installed" "apt-get install -y docker-ce docker-ce-cli containerd.io"
fi

if docker compose version >/dev/null 2>&1; then
    ok "compose plugin is installed  ($(docker compose version --short 2>/dev/null))"
else
    bad "the compose plugin is missing (docker compose, two words)" \
        "apt-get install -y docker-compose-plugin"
fi

if docker buildx version >/dev/null 2>&1; then
    ok "buildx plugin is installed"
else
    warn "buildx is missing — plain builds still work" "apt-get install -y docker-buildx-plugin"
fi

for c in curl git jq; do
    command -v "$c" >/dev/null 2>&1 && ok "$c is installed" \
        || warn "$c is not installed" "apt-get install -y $c"
done

# ---------------------------------------------------------------- 2. service
head_ '2. Service'

if systemctl is-active --quiet docker 2>/dev/null; then
    ok "the docker service is running"
else
    bad "the docker service is not running" "systemctl start docker"
fi

if systemctl is-enabled --quiet docker 2>/dev/null; then
    ok "the docker service starts at boot"
else
    bad "the docker service will NOT start at boot" "systemctl enable docker"
fi

if docker info >/dev/null 2>&1; then
    ok "the docker daemon answers"
else
    bad "cannot talk to the docker daemon" "run as root, or add yourself: usermod -aG docker \$USER"
fi

# ---------------------------------------------------------------- 3. daemon.json
head_ '3. Daemon settings'

DJ=/etc/docker/daemon.json
if [ -f "$DJ" ]; then
    ok "$DJ exists"
    if grep -q '"max-size"' "$DJ" 2>/dev/null; then
        ok "a container log size limit is set"
    else
        warn "no log size limit — one noisy container can fill the disk" \
             'add "log-opts": { "max-size": "20m", "max-file": "5" }'
    fi
    grep -q '"live-restore"' "$DJ" 2>/dev/null \
        && ok "live-restore is on (containers survive a daemon restart)" \
        || warn "live-restore is off" 'add "live-restore": true'
    if command -v python3 >/dev/null 2>&1; then
        python3 -c "import json,sys; json.load(open('$DJ'))" 2>/dev/null \
            && ok "$DJ is valid JSON" \
            || bad "$DJ is NOT valid JSON — docker will refuse to start" "fix the syntax, then: systemctl restart docker"
    fi
else
    warn "$DJ does not exist — no server-wide log limit" "create it, then: systemctl restart docker"
fi

# ---------------------------------------------------------------- 4. group
head_ '4. Users and the docker group'

if getent group docker >/dev/null 2>&1; then
    ok "the docker group exists"
    MEMBERS=$(getent group docker | cut -d: -f4)
    if [ -n "$MEMBERS" ]; then
        ok "members: $MEMBERS"
    else
        warn "no one is in the docker group — only root can run docker" "usermod -aG docker <adminuser>"
    fi
    # A site user in the docker group can mount / into a container and become
    # root on the whole box. Compare the members against the owners of the
    # website folders rather than guessing from the user name.
    SITE_OWNERS=$(stat -c '%U' /var/www/html/*/ 2>/dev/null | sort -u)
    for u in $(printf '%s' "$MEMBERS" | tr ',' ' '); do
        if printf '%s\n' "$SITE_OWNERS" | grep -qx "$u"; then
            warn "$u owns a website AND is in the docker group" \
                 "that is root access for that site: gpasswd -d $u docker"
        fi
    done
else
    bad "the docker group does not exist" "it is normally created by the package — reinstall docker-ce"
fi

if id -u www-data >/dev/null 2>&1; then
    WGID=$(id -g www-data)
    if [ "$WGID" = "33" ]; then
        ok "www-data gid is 33 (matches the images)"
    else
        bad "www-data gid is $WGID, the images create 33" \
            "the FPM socket group will not match nginx — fix before going live"
    fi
else
    bad "there is no www-data user on this host" "nginx and the FPM socket share that group"
fi

# ---------------------------------------------------------------- 5. run test
head_ '5. Can it actually run a container'

if docker run --rm hello-world >/dev/null 2>&1; then
    ok "docker run works (hello-world)"
else
    bad "docker cannot run a container" "check: docker run --rm hello-world"
fi

if docker run --rm --network host alpine:3.19 true >/dev/null 2>&1; then
    ok "host networking works (this stack needs it)"
else
    warn "could not test host networking" "check: docker run --rm --network host alpine:3.19 true"
fi

# ---------------------------------------------------------------- 6. folders
head_ '6. Folders the stack needs'

for d in /opt/docker-stack /run/php-docker /var/log/nginx /var/lib/redis /run/redis; do
    [ -d "$d" ] && ok "$d exists" || bad "$d is missing" "mkdir -p $d"
done

if [ -f /etc/tmpfiles.d/php-docker.conf ]; then
    ok "/run/php-docker is recreated after a reboot"
else
    warn "/run/php-docker will be gone after a reboot" \
         "echo 'd /run/php-docker 0755 root www-data -' > /etc/tmpfiles.d/php-docker.conf"
fi

# ---------------------------------------------------------------- 7. host tuning
head_ '7. Host settings'

OC=$(sysctl -n vm.overcommit_memory 2>/dev/null || echo "?")
[ "$OC" = "1" ] && ok "vm.overcommit_memory = 1" \
    || warn "vm.overcommit_memory = $OC (should be 1)" "Redis BGSAVE / AOF rewrite can fail to fork"

SW=$(free -m 2>/dev/null | awk '/^Swap:/{print $2}')
[ -n "${SW:-}" ] && [ "$SW" -gt 0 ] 2>/dev/null && ok "swap is on (${SW} MB)" \
    || warn "no swap — no cushion before the OOM killer" "a 2 GB swapfile is enough"

# ---------------------------------------------------------------- 8. stack
head_ '8. Stack images and containers'

for i in enzipe/php-fpm:8.2-alpine enzipe/nginx:stable-alpine; do
    docker image inspect "$i" >/dev/null 2>&1 && ok "image $i is built" \
        || warn "image $i is not built yet" "build it from /opt/docker-stack"
done

for c in enzipe-nginx enzipe-redis; do
    STATE=$(docker inspect -f '{{.State.Status}}' "$c" 2>/dev/null)
    HEALTH=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$c" 2>/dev/null)
    if [ "${STATE:-}" = "running" ]; then
        case "$HEALTH" in
            healthy|none) ok "container $c is running ($HEALTH)" ;;
            *)            warn "container $c is running but $HEALTH" "docker logs --tail 30 $c" ;;
        esac
    elif [ -n "${STATE:-}" ]; then
        warn "container $c exists but is $STATE" "docker start $c"
    else
        warn "container $c does not exist yet" "cd /opt/docker-stack && docker compose up -d"
    fi
done

# ---------------------------------------------------------------- summary
printf '\n%s------------------------------------------------------------%s\n' "$B" "$N"
printf '  passed %s%d%s   failed %s%d%s   warnings %s%d%s\n' \
       "$G" "$PASS" "$N" "$R" "$FAIL" "$N" "$Y" "$WARN" "$N"

if [ "$FAIL" -eq 0 ]; then
    printf '  %sDocker installation is complete.%s' "$G" "$N"
    [ "$WARN" -gt 0 ] && printf ' %d warning(s) to look at.' "$WARN"
    printf '\n\n'
    exit 0
else
    printf '  %s%d required check(s) failed — fix those before going on.%s\n\n' "$R" "$FAIL" "$N"
    exit 1
fi
