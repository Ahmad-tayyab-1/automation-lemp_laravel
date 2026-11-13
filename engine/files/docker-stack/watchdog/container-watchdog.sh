#!/usr/bin/env bash
# Container watchdog -> Discord alert + auto-restart.
#
# What it does, in order:
#   1. reads status + health of EVERY container in ONE `docker inspect` call
#   2. any container unhealthy (or down while it should be up):
#        -> Discord alert, EVERY time it is seen (no counter gating)
#        -> `docker restart` on it (same container ID, new process inside)
#   3. container back to `healthy` -> one recovery alert that also says WHO
#      brought it back: this script, Docker's own restart policy, or a human
#
# Two modes, both installed as systemd units:
#   sweep   (timer, every 60s)    - one look at every container
#   events  (service, always on)  - tails `docker events`, reacts in ~1s
#
# `starting` is never acted on: a container that is still warming up is
# neither broken nor recovered, so the script leaves it alone.
#
# Safety rails (all tunable in the config file):
#   RESTART_COOLDOWN   same container is not restarted again inside this window
#   NO_RESTART_REGEX   these are alerted about but never restarted (stateful)
#   MAX_PARALLEL_FAIL  this many broken at once = the cause is outside a
#                      container, so: one summary alert, no restarts at all
set -uo pipefail

CONF="${WATCHDOG_CONF:-/opt/docker-stack/watchdog/watchdog.conf}"
[ -r "$CONF" ] || { echo "missing config: $CONF" >&2; exit 1; }
# shellcheck disable=SC1090
. "$CONF"

: "${DISCORD_WEBHOOK:?DISCORD_WEBHOOK not set in $CONF}"

STATE_DIR="${STATE_DIR:-/var/lib/container-watchdog}"
LOG_LINES="${LOG_LINES:-10}"
IGNORE_REGEX="${IGNORE_REGEX:-}"
ENABLE_RESTART="${ENABLE_RESTART:-yes}"
RESTART_COOLDOWN="${RESTART_COOLDOWN:-120}"
NO_RESTART_REGEX="${NO_RESTART_REGEX:-redis}"
MAX_PARALLEL_FAIL="${MAX_PARALLEL_FAIL:-8}"
MASS_ALERT_EVERY="${MASS_ALERT_EVERY:-600}"
EVENT_SETTLE="${EVENT_SETTLE:-3}"
# A container somebody stopped on purpose is not a fault. Default: alert once,
# then leave it alone. Set to yes to have the watchdog start it again anyway.
RESTART_MANUALLY_STOPPED="${RESTART_MANUALLY_STOPPED:-no}"
# Which log lines are worth showing in an alert. Everything else is traffic noise.
LOG_ERROR_REGEX="${LOG_ERROR_REGEX:-(error|exception|fatal|critical|fail|refus|timeout|timed out|denied|cannot|can.t|unable|panic|segfault|killed|out of memory|no such|not found|warning)}"

SERVER_NAME="$(hostname -f 2>/dev/null || hostname)"
SERVER_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
mkdir -p "$STATE_DIR" 2>/dev/null || true
LOCKFILE="$STATE_DIR/.lock"

# Discord embed colours (decimal)
COLOR_CRIT=15158332     # red
COLOR_WARN=15844367     # amber
COLOR_OK=3066993        # green

# Everything the script needs to judge a container, in one template.
# NOTE: two traps here. `with` not `if` (an `if .State.Health` breaks the whole
# batch on containers with no healthcheck), and `.ID` not `.Id` - a field name
# the Go struct does not have makes docker re-run the template against the raw
# JSON map, where `Health` is simply absent, which breaks it the same way.
INSPECT_FMT='{{.ID}}|{{.Name}}|{{.State.Status}}|{{with .State.Health}}{{.Status}}{{else}}none{{end}}|{{.RestartCount}}|{{.HostConfig.RestartPolicy.Name}}|{{.State.ExitCode}}|{{.State.OOMKilled}}|{{.Config.Image}}|{{.State.StartedAt}}'

log() { logger -t container-watchdog "$*" 2>/dev/null || true; }
now_human() { date '+%Y-%m-%d %H:%M:%S'; }

matches() {   # matches <text> <regex>   (an empty regex matches nothing)
    [ -n "${2:-}" ] || return 1
    printf '%s' "$1" | grep -Eq "$2"
}

# Numeric read that can never blow up on a missing or corrupt file.
read_num() {
    local v=0
    [ -f "$1" ] && v=$(cat "$1" 2>/dev/null)
    [[ "$v" =~ ^[0-9]+$ ]] || v=0
    printf '%s' "$v"
}
read_str() { cat "$1" 2>/dev/null || true; }

# ---------------------------------------------------------------- discord

json_escape() { python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))'; }

# Discord rejects an embed description over 4096 chars.
trim() { cut -c1-3500; }

send_discord() {
    local title="$1" color="$2" body="$3" payload
    payload=$(cat <<JSON
{
  "username": "Container Watchdog",
  "embeds": [{
    "title": $(printf '%s' "${title:0:250}" | json_escape),
    "color": $color,
    "description": $(printf '%s' "$body" | trim | json_escape)
  }]
}
JSON
)
    curl -sS -m 15 -H 'Content-Type: application/json' -X POST \
         -d "$payload" "$DISCORD_WEBHOOK" >/dev/null 2>&1 \
      || log "discord POST failed: $title"
}

# ---------------------------------------------------------------- evidence

# Docker keeps the output of the last five health probes. That output IS the
# reason a container is unhealthy, straight from the horse's mouth.
# NOTE: it is only there if the healthcheck command actually prints something.
# A command written with `grep -q` or `>/dev/null` throws its own output away,
# so Docker has nothing to store and this comes back empty.
# prints: <failing-streak>|<last probe exit code>|<last probe output>
health_detail() {
    docker inspect --format '{{json .State.Health}}' "$1" 2>/dev/null | python3 -c '
import json, sys
try:
    h = json.load(sys.stdin)
except Exception:
    print("||"); raise SystemExit
if not isinstance(h, dict):
    print("||"); raise SystemExit
lg = h.get("Log") or []
last = lg[-1] if isinstance(lg, list) and lg else {}
out = (last.get("Output") or "").strip().replace("\n", " ").replace("`", "")[:280]
print("%s|%s|%s" % (h.get("FailingStreak", ""), last.get("ExitCode", ""), out))
' 2>/dev/null || printf '%s' '||'
}

# Did a human stop this container, or did it die? Docker records the answer in
# the container's own state file. It is NOT in `docker inspect`, and it is an
# internal file, so every failure here is treated as "no" and the old behaviour
# (alert + restart) stands - this can never make the watchdog do less than before.
manually_stopped() {   # manually_stopped <full-container-id>
    local f="/var/lib/docker/containers/$1/config.v2.json"
    [ -r "$f" ] || return 1
    grep -qE '"HasBeenManuallyStopped"[[:space:]]*:[[:space:]]*true' "$f" 2>/dev/null
}

# Show the lines that explain something, not the last N lines of traffic noise.
relevant_logs() {
    local name="$1" raw hits
    raw=$(docker logs --tail 300 "$name" 2>&1 | cut -c1-200)
    if [ -z "$raw" ]; then
        printf '%s' "(container produced no log output)"
        return
    fi
    hits=$(printf '%s\n' "$raw" | grep -Ei "$LOG_ERROR_REGEX" | tail -n "$LOG_LINES")
    if [ -n "$hits" ]; then
        printf '%s' "$hits"
    else
        printf '%s\n%s' "(no error line found - last $LOG_LINES lines instead)" \
                        "$(printf '%s\n' "$raw" | tail -n "$LOG_LINES")"
    fi
}

# ---------------------------------------------------------------- reasons

reason_unhealthy() {
    local name="$1" streak ec out r
    IFS='|' read -r streak ec out <<< "$(health_detail "$name")"
    r="Healthcheck is failing - the container is running but not answering."
    [ -n "$streak" ] && [ "$streak" != "0" ] && \
        r="Healthcheck is failing - $streak probe(s) in a row have failed. The container is running but not answering."
    if [ -n "$out" ]; then
        r="$r
Docker's last probe exited \`$ec\` and said:
\`$out\`"
    elif [ -n "$ec" ]; then
        r="$r
Docker's last probe exited \`$ec\` and printed nothing (the healthcheck command discards its own output), so the detail is in the log below."
    fi
    printf '%s' "$r"
}

reason_down() {
    local status="$1" ec="$2" oom="$3" policy="$4" r
    # A paused container has not crashed and its exit code means nothing, so it
    # gets its own wording and never the exit-code explanations below.
    if [ "$status" = "paused" ]; then
        printf '%s' "Container is **paused** - it is frozen and serving nothing. A restart policy does not apply to a paused container, so Docker will not fix this by itself."
        return
    fi
    if [ "$status" = "restarting" ]; then
        r="Container is crash-looping - status \`restarting\`, last exit code \`$ec\`. Docker's restart policy keeps starting it and the process inside keeps dying."
    else
        r="Container is not running - status \`$status\`, exit code \`$ec\`."
    fi
    if [ "$oom" = "true" ]; then
        r="$r
The kernel OOM killer killed it - the server ran out of memory."
    else
        case "$ec" in
            0)   r="$r
Exit code 0 means the process finished by itself (a queue worker with \`--max-time\` does this on purpose)." ;;
            1)   r="$r
Exit 1 means the process itself reported an error - see the log below." ;;
            137) r="$r
Exit 137 = SIGKILL, killed from outside: usually out of memory, or a stop that timed out." ;;
            139) r="$r
Exit 139 = segmentation fault inside the process." ;;
        esac
    fi
    printf '%s' "$r
Its restart policy is \`$policy\`, so Docker should have brought it back and has not."
}

# ---------------------------------------------------------------- actions

# Prints "<verdict>|<human text>", verdict = ok | failed | skipped.
# It must come back through stdout: this is called in a command substitution,
# which is a subshell, so a global variable set in here would be lost.
restart_container() {
    local name="$1" id="$2"
    if [ "$ENABLE_RESTART" != "yes" ]; then
        printf '%s' "skipped|No restart attempted - \`ENABLE_RESTART=$ENABLE_RESTART\` in the config. Alert only."
        return
    fi
    if matches "$name" "$NO_RESTART_REGEX"; then
        printf '%s' "skipped|No restart attempted - this container is on the never-restart list (\`NO_RESTART_REGEX\`), because restarting it could do more harm than good. Needs a human."
        return
    fi

    local last now ago
    last=$(read_num "$STATE_DIR/$name.lastrestart")
    now=$(date +%s); ago=$((now - last))
    if [ "$last" -gt 0 ] && [ "$ago" -lt "$RESTART_COOLDOWN" ]; then
        printf '%s' "skipped|No restart attempted - it was already restarted ${ago}s ago and the cooldown is ${RESTART_COOLDOWN}s. Restarting again this fast would not help."
        return
    fi

    printf '%s\n' "$now" > "$STATE_DIR/$name.lastrestart"
    local err
    if err=$(docker restart "$name" 2>&1); then
        printf '%s\n' "script" > "$STATE_DIR/$name.restartedby"
        log "restarted $name"
        printf '%s' "ok|Watchdog ran \`docker restart $name\` - same container ID \`${id:0:12}\`, fresh process inside."
    else
        log "restart FAILED for $name: $err"
        printf '%s' "failed|Watchdog ran \`docker restart $name\` and **it failed**:
\`$(printf '%s' "$err" | tr '\n' ' ' | cut -c1-250)\`
This needs a human."
    fi
}

# ---------------------------------------------------------------- alerts

# One shape for every alert: what / where / which / why / evidence / what was
# done / when.
alert_body() {   # alert_body <label-less> <name> <id> <reason> <log> <action>
    local name="$1" id="$2" reason="$3" logs="$4" action="$5"
    printf '%s' "**Server:**
$SERVER_NAME ($SERVER_IP)

**Container:**
$name (\`${id:0:12}\`)

**Reason:**
$reason

**Log:**
\`\`\`
$logs
\`\`\`

**Action:**
$action

**Time:** $(now_human)"
}

handle_fail() {
    local line="$1"
    local id name status health rc policy ec oom image started
    IFS='|' read -r id name status health rc policy ec oom image started <<< "$line"

    local n; n=$(read_num "$STATE_DIR/$name.fail"); n=$((n + 1))
    printf '%s\n' "$n" > "$STATE_DIR/$name.fail"
    [ -f "$STATE_DIR/$name.since" ] || date +%s > "$STATE_DIR/$name.since"
    # RestartCount as it was when the incident began, so the recovery alert can
    # tell whether Docker's own policy was the thing that fixed it.
    [ -f "$STATE_DIR/$name.rc" ] || printf '%s\n' "$rc" > "$STATE_DIR/$name.rc"

    # Somebody stopping a container on purpose is not a fault, so it gets its own
    # wording, is not restarted, and is reported once instead of every sweep.
    # Nothing pauses a container by itself - no kernel, no crash, no policy does
    # it - and Docker flags a manual stop, so both are somebody's decision. The
    # watchdog reports each one once and then leaves it alone.
    local deliberate="no"
    if [ "$status" = "paused" ]; then
        deliberate="paused"
    elif [ "$status" != "running" ] && manually_stopped "$id"; then
        deliberate="stopped"
    fi
    if [ "$deliberate" != "no" ] && [ "$n" -gt 1 ]; then
        return 0            # already reported; stay quiet while it is down
    fi

    local reason
    if [ "$deliberate" = "stopped" ]; then
        reason="Container was stopped deliberately - Docker's own \`HasBeenManuallyStopped\` flag is set, so this was a \`docker stop\` / \`compose down\`, not a crash. Status \`$status\`, exit code \`$ec\`."
    elif [ "$status" = "running" ]; then
        reason=$(reason_unhealthy "$name")
    else
        reason=$(reason_down "$status" "$ec" "$oom" "$policy")
    fi

    # Read the logs BEFORE restarting, or a restart wipes the evidence.
    local logs; logs=$(relevant_logs "$name")

    local out verdict action
    if [ "$deliberate" != "no" ] && [ "$RESTART_MANUALLY_STOPPED" != "yes" ]; then
        local verb="stopped"
        [ "$deliberate" = "paused" ] && verb="paused"
        out="skipped|No restart attempted - somebody $verb this container on purpose. The watchdog will not undo that. (Set \`RESTART_MANUALLY_STOPPED=yes\` in the config to change this.)"
    else
        out=$(restart_container "$name" "$id")
    fi
    verdict="${out%%|*}"          # ok | failed | skipped
    action="${out#*|}"

    # The label says what is wrong, in plain words.
    local label colour="$COLOR_CRIT"
    if [ "$deliberate" = "stopped" ]; then
        label="⏹️ Container Stopped"
        colour="$COLOR_WARN"       # amber: somebody meant to do this
    elif [ "$deliberate" = "paused" ]; then
        label="⏸️ Container Paused"
        colour="$COLOR_WARN"
    elif [ "$verdict" = "failed" ]; then
        label="⛔ Container Restart Failed"
    elif [ "$status" = "running" ]; then
        if [ "$n" -gt 1 ]; then label="🟠 Container Still Unhealthy After Restart"
        else                    label="🔴 Container Unhealthy"; fi
    else
        if [ "$n" -gt 1 ]; then label="🟠 Container Still Down After Restart"
        else                    label="🔴 Container Crashed"; fi
    fi

    send_discord "$label" "$colour" \
        "$(alert_body "$name" "$id" "$reason" "$logs" "$action")"
}

handle_ok() {
    local name="$1" rc_now="$2" id="$3"
    local f="$STATE_DIR/$name.fail"
    [ -f "$f" ] || return 0          # was fine all along -> stay quiet

    local n down="unknown" since by rc_before cause label
    n=$(read_num "$f")
    since=$(read_num "$STATE_DIR/$name.since")
    [ "$since" -gt 0 ] && down="$(( $(date +%s) - since ))s"
    by=$(read_str "$STATE_DIR/$name.restartedby")
    rc_before=$(read_num "$STATE_DIR/$name.rc")
    [[ "$rc_now" =~ ^[0-9]+$ ]] || rc_now="$rc_before"

    if [ "$by" = "script" ]; then
        cause="This watchdog restarted it with \`docker restart\` and that fixed it (same container ID)."
        label="✅ Container Recovered"
    elif [ "$rc_now" -gt "$rc_before" ]; then
        cause="Docker's own \`restart\` policy brought it back by itself - the watchdog did not touch it (RestartCount $rc_before -> $rc_now)."
        label="✅ Container Recovered"
    else
        cause="No restart happened at all - it either healed by itself or someone fixed it by hand."
        label="✅ Container Healthy"
    fi

    rm -f "$f" "$STATE_DIR/$name.since" "$STATE_DIR/$name.rc" "$STATE_DIR/$name.restartedby"
    # .lastrestart is kept on purpose: a container that keeps flapping should
    # still be held by the cooldown.

    send_discord "$label" "$COLOR_OK" \
"**Server:**
$SERVER_NAME ($SERVER_IP)

**Container:**
$name (\`${id:0:12}\`)

**Reason:**
Container is running and \`healthy\` again.
$cause

**Was broken for:** $down
**Alerts sent during this incident:** $n

**Time:** $(now_human)"
}

# A deleted container vanishes from `docker inspect`, so the 60s sweep can never
# see this - it is only knowable from the event stream, at the moment it happens.
handle_destroyed() {
    local name="$1" id="$2"
    case "$name" in ""|*/*|*' '*) return 0 ;; esac   # never glob on a junk name
    send_discord "🗑️ Container Deleted" "$COLOR_WARN" \
"**Server:**
$SERVER_NAME ($SERVER_IP)

**Container:**
$name (\`${id:0:12}\`)

**Reason:**
The container was removed (\`docker rm\` / \`compose down\`). It no longer exists, so there is nothing left to restart or watch - it has simply disappeared from the watchdog's view.
If this was not planned, the site it served is down.

**Action:**
Nothing to do automatically. Bring it back with \`docker compose up -d\` from its project folder.

**Time:** $(now_human)"
    rm -f "$STATE_DIR/$name.fail" "$STATE_DIR/$name.since" "$STATE_DIR/$name.rc" \
          "$STATE_DIR/$name.restartedby" "$STATE_DIR/$name.lastrestart"
}

# Too many broken at once -> the cause is outside the containers.
mass_alert() {
    local n="$1" names="$2"
    local stamp="$STATE_DIR/.mass" now last
    now=$(date +%s); last=$(read_num "$stamp")
    [ "$last" -gt 0 ] && [ $((now - last)) -lt "$MASS_ALERT_EVERY" ] && return 0
    printf '%s\n' "$now" > "$stamp"

    send_discord "⛔ Server-Wide Failure - $n containers broken at once" "$COLOR_CRIT" \
"**Server:**
$SERVER_NAME ($SERVER_IP)

**Container:**
$n containers at the same time (list below)

**Reason:**
$n containers are unhealthy or down together. That is more than \`MAX_PARALLEL_FAIL=$MAX_PARALLEL_FAIL\`, so the cause is almost certainly *outside* the containers - database, disk, memory or network.

**Affected containers:**
\`\`\`
$names\`\`\`

**Action:**
Nothing was restarted. Restarting this many containers would only add load. Check the host first: \`df -h\`, \`free -m\`, MariaDB, Redis.

**Time:** $(now_human)"
}

# ---------------------------------------------------------------- snapshot

# One docker call for every container. ~0.2s whether there are 5 or 60.
snapshot() {
    local out
    out=$(docker ps -aq 2>/dev/null | xargs -r docker inspect --format "$INSPECT_FMT" 2>&1)
    # A broken template would silently hide containers instead of failing loudly.
    if printf '%s\n' "$out" | grep -q 'template parsing error'; then
        log "INSPECT_FMT is broken - some containers are invisible to the watchdog"
        out=$(printf '%s\n' "$out" | grep -v 'template parsing error')
    fi
    printf '%s\n' "$out"
}

# ---------------------------------------------------------------- core

# process [only-this-container]
process() {
    local only="${1:-}"
    local snap; snap="$(snapshot)"
    if [ -z "$snap" ]; then
        log "snapshot empty - docker not answering?"
        return 0
    fi

    local fails=() oks=() names=""
    local id name status health rc policy ec oom image started

    while IFS='|' read -r id name status health rc policy ec oom image started; do
        [ -n "${name:-}" ] || continue
        name="${name#/}"
        matches "$name" "$IGNORE_REGEX" && continue

        # Still warming up: neither broken nor recovered.
        [ "$health" = "starting" ] && continue

        local line="$id|$name|$status|$health|$rc|$policy|$ec|$oom|$image|$started"

        if [ "$status" = "running" ]; then
            case "$health" in
                healthy|none) oks+=("$line") ;;
                *)            fails+=("$line"); names+="$name  ($status/$health)"$'\n' ;;
            esac
        elif [ "$policy" = "always" ] || [ "$policy" = "unless-stopped" ]; then
            fails+=("$line"); names+="$name  ($status, exit $ec)"$'\n'
        fi
        # anything else was stopped on purpose -> ignore completely
    done <<< "$snap"

    local nfail=${#fails[@]}

    if [ "$nfail" -ge "$MAX_PARALLEL_FAIL" ]; then
        mass_alert "$nfail" "$names"
        return 0
    fi
    rm -f "$STATE_DIR/.mass"

    local line
    for line in ${fails[@]+"${fails[@]}"}; do
        name=$(printf '%s' "$line" | cut -d'|' -f2)
        [ -n "$only" ] && [ "$name" != "$only" ] && continue
        handle_fail "$line"
    done

    for line in ${oks[@]+"${oks[@]}"}; do
        IFS='|' read -r id name status health rc policy ec oom image started <<< "$line"
        [ -n "$only" ] && [ "$name" != "$only" ] && continue
        handle_ok "$name" "$rc" "$id"
    done
}

# ---------------------------------------------------------------- modes

sweep() {
    exec 9>"$LOCKFILE"
    flock -n 9 || { log "sweep skipped, another run holds the lock"; return 0; }
    process
}

events() {
    # Docker only emits health_status on a CHANGE, so this is quiet in normal
    # operation. The 60s sweep is what catches a container that stays broken.
    # `|` as the separator, not a space: the action itself contains one
    # ("health_status: unhealthy"), so splitting on whitespace puts half the
    # action into the name and the container name is lost. A container name can
    # never contain `|`, so this split is always safe.
    docker events --format '{{.Action}}|{{.Actor.Attributes.name}}|{{.Actor.ID}}' \
        --filter 'type=container' \
        --filter 'event=die' \
        --filter 'event=oom' \
        --filter 'event=health_status' \
        --filter 'event=start' \
        --filter 'event=stop' \
        --filter 'event=pause' \
        --filter 'event=unpause' \
        --filter 'event=destroy' 2>/dev/null |
    while IFS='|' read -r action name id; do
        [ -n "${name:-}" ] || continue
        matches "$name" "$IGNORE_REGEX" && continue
        case "$action" in
            destroy)
                # Nothing left to inspect, so report straight away.
                ( flock -w 90 9 || exit 0; handle_destroyed "$name" "$id" ) 9>"$LOCKFILE"
                ;;
            die|oom|stop|start|pause|unpause|*unhealthy*|*healthy*)
                sleep "$EVENT_SETTLE"   # let restart:always finish its job first
                ( flock -w 90 9 || exit 0; process "$name" ) 9>"$LOCKFILE"
                ;;
        esac
    done
    log "docker events stream ended - systemd will restart this service"
}

status() {
    printf '%-32s %-11s %-10s %-5s %-16s %s\n' CONTAINER STATUS HEALTH RST# POLICY WATCHDOG
    printf '%.0s-' {1..110}; echo
    local id name st he rc po ec oom im sa note
    # shellcheck disable=SC2034  # im/sa are read only to consume their fields
    while IFS='|' read -r id name st he rc po ec oom im sa; do
        name="${name#/}"
        [ -n "$name" ] || continue
        note="ok"
        matches "$name" "$IGNORE_REGEX" && note="ignored"
        [ "$he" = "starting" ] && note="warming up"
        if [ "$note" = "ok" ]; then
            if [ "$st" = "running" ] && { [ "$he" = "healthy" ] || [ "$he" = "none" ]; }; then
                [ "$he" = "none" ] && note="no healthcheck - blind"
            else
                note="WOULD ALERT"
                matches "$name" "$NO_RESTART_REGEX" && note="WOULD ALERT (no restart)"
            fi
        fi
        printf '%-32s %-11s %-10s %-5s %-16s %s\n' "$name" "$st" "$he" "$rc" "$po" "$note"
    done <<< "$(snapshot)"
    echo
    echo "restart=$ENABLE_RESTART  cooldown=${RESTART_COOLDOWN}s  no-restart=/$NO_RESTART_REGEX/  mass-brake=$MAX_PARALLEL_FAIL"
}

case "${1:-sweep}" in
    sweep)  sweep ;;
    events) events ;;
    status) status ;;
    test)   send_discord "🔔 Watchdog Test" "$COLOR_WARN" \
"**Server:**
$SERVER_NAME ($SERVER_IP)

**Container:**
none - this is a test message

**Reason:**
Watchdog is installed and can post to this channel. No action needed.

**Log:**
\`\`\`
restart enabled  : $ENABLE_RESTART
restart cooldown : ${RESTART_COOLDOWN}s
never restarted  : /$NO_RESTART_REGEX/
mass brake       : $MAX_PARALLEL_FAIL containers
log lines shown  : $LOG_LINES
\`\`\`

**Action:**
Nothing - test only.

**Time:** $(now_human)" ;;
    *)      echo "usage: $0 {sweep|events|status|test}" >&2; exit 2 ;;
esac
