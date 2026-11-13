#!/usr/bin/env bash
# deploy.sh -- Universal Deploy Tool (bash edition)
# Normal user deploy tool for Laravel sites. Asks what to deploy, then runs engine/run.sh (plain bash,
# templates in engine/templates) on this machine or on a remote target over ssh. No Ansible.
set -Eeuo pipefail
umask 077

export LC_ALL=C.UTF-8
export LANG=C.UTF-8

BASE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
CALLER_PWD=$PWD   # relative paths typed by the user are read from here first (resolve_local_path)
SITES_JSON="$BASE/sites.json"
TARGETS_JSON="$BASE/targets.json"
TRAFFIC_JSON="$BASE/traffic.json"
SETUPS_FILE="$BASE/setups.conf"
DATA="$BASE/data"
LOG_FILE="$DATA/logs/$(date +%F).log"

# The person running the deploy: SUDO_USER only counts when we really run as root through sudo
if [[ $EUID -eq 0 && -n ${SUDO_USER:-} ]]; then CURRENT_USER=$SUDO_USER; else CURRENT_USER=$(id -un); fi
TARGET='' SETUP='' SITE='' BRANCH='' TRAFFIC='' ENVIRONMENT='' DB_MODE='' TLS_MODE='' PHP_VERSION=''
SWITCH_ACTION='' SWITCH_SITES_JSON='[]' SWITCH_SUMMARY='' TARGET_MARKER=''
OLD_SITES=() MOVE_SITES=() DUMP_SITES=() MOVE_DUMP='' KEEP_DB_PASSWORD=0 CLI_SWITCH=''
STACK_CONFIGURED=0 STACK_SETTINGS_JSON='{}' STACK_LEGACY=0 STACK_CONFIG=0 STACK_CONFIGURE=0
STACK_ADMIN_IPS='' STACK_WHITELIST_IPS='' STACK_WEBHOOK_STATE='' CLI_STACK_ADMIN_IPS='' CLI_STACK_WHITELIST_IPS=''
# Defaults from the docker-stack zip (snippets/allowed_admin_ips.conf and the geo $whitelist in nginx.conf)
STACK_DEFAULT_ADMIN_IPS='137.59.224.209 165.232.115.58 110.39.174.74 110.39.174.75 110.39.174.76 110.39.174.77 110.39.174.78 209.38.213.39'
STACK_DEFAULT_WHITELIST_IPS='93.115.200.155 93.115.200.156 93.115.200.157 93.115.200.158 93.115.200.159 137.59.224.209'
CLI_SITE_USER='' SITE_USER='' SITE_USER_NOW='' CLI_BRANCH='' CLI_TRAFFIC='' CLI_PHP='' CLI_TLS='' CLI_CERT_FILE='' CLI_CERT_KEY=''
CLI_CERT_PATH='' CLI_KEY_PATH='' CLI_CERTBOT_EMAIL=''
CLI_DB_HOST='' CLI_DB_PORT='' CLI_DB_NAME='' CLI_DB_USER='' CLI_DB_BACKUP=''
CLI_INSTALL='' SERVER_PARTS=() SERVER_PHP=() PROBE_INSTALLED='{}' PROBE_PARTS='{}' PROBE_PHP_STATES='{}' PROBE_SECOND_KIND=''
export GIT_TERMINAL_PROMPT=0
CLI_REMOVE='' CLI_DB_SWAP='' CLI_SNAPSHOT='' FORCE_REMOVE=0
CLI_FW_ACTION='' CLI_FW_PORTS='' CLI_FW_UDP='' CLI_FW_SSH='' CLI_FW_ALLOW='' CLI_FW_IGNORE='' CLI_FW_DENY='' CLI_FW_PORT_IP=''
CLI_FW_OUT='' CLI_FW_PING='' CLI_FW_SSH_LIMIT='' CLI_FW_SSH_BLOCK='' CLI_FW_EMAIL='' CLI_FW_TESTING='' FW_PORT_RULES=()
CERT_FILE='' KEY_FILE='' TLS_CERT_PATH='' TLS_KEY_PATH='' CERTBOT_EMAIL='' PEM_PENDING='' PEM_LINE=''
ASSUME_YES=0 DRY_RUN=0 ASK_BECOME=0 SKIP_REPO_CHECK=0 SERVER_REFRESH=0 PLAIN_UI=0 UI_TITLE='' SUMMARY_TEXT='' NEED_ROOT=1 PROBE_SITES='[]' PROBE_FOREIGN_VHOSTS=''
POSITIONAL=() VERBOSE=0 SHOW_TIMINGS=0
TMP_DIR='' NEW_SITE_DOMAIN='' KEY_SHOWN='' KEY_WHERE='' VERIFY_MSG=''
# existing = files already on the target, paste = PEM pasted in the terminal, certbot = Let's Encrypt.
# files (certificate files on this machine) and keep (= existing in /etc/nginx/cert) are kept for CLI use.
TLS_MODES=(none existing paste certbot files keep)
TLS_TARGET_DIR=/etc/nginx/cert
TLS_LEGACY_DIR=/etc/ssl/deployer   # older deploys; the engine moves a site's certificate from there
PHP_VERSIONS=(8.0 8.1 8.2 8.3 8.4)

# ---------------------------------------------------------------- helpers
if [[ -t 2 ]]; then C_RED=$'\033[31m'; C_YEL=$'\033[33m'; C_GRN=$'\033[32m'; C_OFF=$'\033[0m'
else C_RED=''; C_YEL=''; C_GRN=''; C_OFF=''; fi
info()  { printf '%s==>%s %s\n' "$C_GRN" "$C_OFF" "$*" >&2; ui_note "$*"; }
warn()  { printf '%swarn:%s %s\n' "$C_YEL" "$C_OFF" "$*" >&2; }
die()   { printf '%serror:%s %s\n' "$C_RED" "$C_OFF" "$*" >&2; exit 1; }
audit() {
  mkdir -p "$DATA/logs"
  chmod 0700 "$DATA/logs" 2>/dev/null || true
  touch "$LOG_FILE" 2>/dev/null || true
  chmod 0600 "$LOG_FILE" 2>/dev/null || true
  printf '%s user=%s %s\n' "$(date -Is)" "$CURRENT_USER" "$*" >> "$LOG_FILE"
}

need_cmds() {
  local c missing=()
  for c in "$@"; do command -v "$c" >/dev/null 2>&1 || missing+=("$c"); done
  ((${#missing[@]} == 0)) || die "Missing commands: ${missing[*]} (run install.sh)"
}

# ---------------------------------------------------------------- questions
# Questions are whiptail menus when whiptail is installed and this runs in a terminal; otherwise
# (or with --plain, or DEPLOY_UI=plain) numbered plain prompts. Flags and -y never ask anything.
# Cancel or Esc in a menu ends the run; nothing on the target is changed before the final "Continue?".
UI=plain
ui_init() {
  if ((! PLAIN_UI)) && [[ ${DEPLOY_UI:-} != plain && ${TERM:-dumb} != dumb && -t 0 && -t 2 ]] \
     && command -v whiptail >/dev/null 2>&1; then
    UI=whiptail
    ui_screen_prepare
  fi
}

# ---- one screen for all the questions
# Every whiptail run switches the terminal to its alternate screen and back, so the terminal showed for
# a moment between two questions. Instead, deploy.sh switches once (ui_screen_on, before the first
# question) and back once (ui_screen_off: before the deploy runs, before text is pasted into the
# terminal, and on exit). whiptail gets a copy of the terminal description without the switch
# (UI_TERMINFO, made with infocmp/tic); without one the menus work as before. Output printed while the
# questions are on screen is kept in UI_BUF and shown after ui_screen_off.
UI_TERMINFO='' UI_ALT=0 UI_BUF='' UI_FD1='' UI_FD2=''
ui_screen_prepare() {
  local d
  command -v infocmp >/dev/null 2>&1 && command -v tic >/dev/null 2>&1 && command -v tput >/dev/null 2>&1 || return 0
  d=$(mktemp -d) || return 0
  if infocmp -x "$TERM" 2>/dev/null | sed -E 's/(smcup|rmcup)=[^,]*,//g' | tic -x -o "$d" - >/dev/null 2>&1; then
    UI_TERMINFO=$d
  else
    rm -rf "$d"
  fi
}
# ui_screen_on: called in the main shell before each question (wt itself runs in a $(...) subshell)
ui_screen_on() {
  ((! UI_ALT)) && [[ -n $UI_TERMINFO ]] || return 0
  UI_BUF=$(mktemp) || return 0
  tput smcup > /dev/tty 2>/dev/null || true
  exec {UI_FD1}>&1 {UI_FD2}>&2
  exec >> "$UI_BUF" 2>&1
  UI_ALT=1
}
ui_screen_off() {
  ((UI_ALT)) || return 0
  exec 1>&"$UI_FD1" 2>&"$UI_FD2"
  exec {UI_FD1}>&- {UI_FD2}>&-
  UI_ALT=0
  tput rmcup > /dev/tty 2>/dev/null || true
  [[ ! -s $UI_BUF ]] || cat "$UI_BUF" >&2
  rm -f "$UI_BUF"
}

# interactive: questions may be asked (a terminal and no -y)
interactive() { ((! ASSUME_YES)) && [[ -t 0 ]]; }

ui_cancelled() { printf '\n' >&2; info "Cancelled. Nothing was changed."; exit 1; }

ui_trim() { local s=$1; s=${s#"${s%%[![:space:]]*}"}; printf '%s' "${s%"${s##*[![:space:]]}"}"; }

# Theme for the whiptail menus (whiptail's default is white on pink): the terminal's own background and
# text color, so the menus look like the rest of the terminal, a grey border, cyan titles and a teal
# highlight for the selected item and the focused button. whiptail only knows the 16 terminal colors
# ("default" is the terminal's own color; it draws the focused button with "button", the others with
# "compactbutton"). A NEWT_COLORS already set in the environment wins.
: "${NEWT_COLORS:=
root=default,default
roottext=default,default
helpline=gray,default
window=default,default
border=gray,default
shadow=default,default
title=cyan,default
label=default,default
textbox=default,default
acttextbox=black,cyan
entry=cyan,default
disentry=gray,default
button=black,cyan
actbutton=black,cyan
compactbutton=default,default
checkbox=default,default
actcheckbox=black,cyan
listbox=default,default
actlistbox=black,cyan
sellistbox=cyan,default
actsellistbox=black,cyan
emptyscale=,default
fullscale=,cyan
}"
export NEWT_COLORS

# wt ARGS...: whiptail with the answer on stdout (whiptail writes it to stderr). While the question screen
# is on (UI_ALT), it draws on the terminal directly, without switching screens. whiptail reads a text
# that starts with "-" as an option ("---- Deploy summary ----": "unknown option", exit code 1, which
# looked like "No"), so the text after a box option gets a leading space when it starts with "-".
wt() {
  local args=() x box=0
  for x in "$@"; do
    if ((box)) && [[ $x == -* ]]; then x=" $x"; fi
    box=0
    case $x in --msgbox|--yesno|--infobox|--inputbox|--passwordbox|--menu|--checklist|--radiolist|--textbox|--gauge) box=1 ;; esac
    args+=("$x")
  done
  if ((UI_ALT)); then
    local rc=0
    TERMINFO=$UI_TERMINFO whiptail --title "deploy.sh${UI_TITLE:+: $UI_TITLE}" "${args[@]}" 2>&1 > /dev/tty || rc=$?
    # until the next question or message is drawn, the screen shows this instead of the old question
    ui_note "One moment..."
    return "$rc"
  else
    whiptail --title "deploy.sh${UI_TITLE:+: $UI_TITLE}" "${args[@]}" 3>&1 1>&2 2>&3
  fi
}

# ui_note TEXT: while the question screen is on, TEXT in a box in the middle of the screen, so progress
# messages ("Verifying repository access...") show while the work runs (they are also kept for later).
# Drawn here: whiptail --infobox exits before its text is drawn and left an empty box.
ui_note() {
  ((UI_ALT)) || return 0
  local cols rows w h top left i line lines=() hl
  cols=$(tput cols 2>/dev/null || echo 80); rows=$(tput lines 2>/dev/null || echo 24)
  w=$((${#1} + 6)); ((w >= 44)) || w=44; ((w <= cols - 4)) || w=$((cols - 4))
  while IFS= read -r line; do lines+=("$line"); done < <(printf '%s\n' "$1" | fold -s -w $((w - 6)))
  h=$((${#lines[@]} + 4)); top=$(((rows - h) / 2 + 1)); left=$(((cols - w) / 2 + 1))
  printf -v hl '%*s' $((w - 2)) ''; hl=${hl// /─}
  {
    printf '\e[0m\e[H\e[2J'
    printf '\e[%d;%dH\e[90m┌%s┐\e[0m' "$top" "$left" "$hl"
    printf '\e[%d;%dH\e[36m deploy.sh \e[0m' "$top" $((left + (w - 11) / 2))
    for ((i = 1; i < h - 1; i++)); do
      printf '\e[%d;%dH\e[90m│\e[0m%*s\e[90m│\e[0m' $((top + i)) "$left" $((w - 2)) ''
    done
    for ((i = 0; i < ${#lines[@]}; i++)); do
      printf '\e[%d;%dH%s' $((top + 2 + i)) $((left + 3)) "${lines[i]}"
    done
    printf '\e[%d;%dH\e[90m└%s┘\e[0m' $((top + h - 1)) "$left" "$hl"
  } > /dev/tty
}

# ui_fit_labels ARRAY MAX STEP: shortens the labels in ARRAY (tag label [state] ...; the label is the
# 2nd of every STEP items) to MAX characters with "...", so no menu line runs past the box
ui_fit_labels() {
  local -n __a=$1
  local max=$2 step=$3 i
  ((max >= 10)) || max=10
  for ((i = 1; i < ${#__a[@]}; i += step)); do
    ((${#__a[i]} <= max)) || __a[i]="${__a[i]:0:max-3}..."
  done
}

# ui_size TEXT [ITEMS] [ITEM_WIDTH]: UI_H, UI_W and UI_L (menu rows) that fit TEXT and the items
ui_size() {
  local text=$1 items=${2:-0} iw=${3:-0} rows cols w line n=0
  rows=$(tput lines 2>/dev/null || echo 24); cols=$(tput cols 2>/dev/null || echo 80)
  w=$((iw + 12)); ((w >= 64)) || w=64
  while IFS= read -r line; do ((${#line} + 6 <= w)) || w=$((${#line} + 6)); done <<< "$text"
  ((w <= cols - 4)) || w=$((cols - 4))
  while IFS= read -r line; do n=$((n + 1 + ${#line} / (w - 4))); done <<< "$text"
  UI_L=$items
  ((n + UI_L + 8 <= rows - 2)) || UI_L=$((rows - 10 - n))
  ((UI_L >= 3 || items == 0)) || UI_L=3
  UI_H=$((n + UI_L + (items > 0 ? 8 : 7)))
  ((UI_H <= rows - 2)) || UI_H=$((rows - 2))
  UI_W=$w
}

ui_error() {
  if [[ $UI == whiptail ]]; then ui_screen_on; ui_size "$1"; wt --msgbox "$1" "$UI_H" "$UI_W" || true
  else warn "$1"; fi
}

ui_msg() {
  if [[ $UI == whiptail ]]; then ui_screen_on; ui_size "$1"; wt --msgbox "$1" "$UI_H" "$UI_W" || ui_cancelled
  else printf '\n%s\n' "$1" >&2; fi
}

# ui_menu VAR TEXT DEFAULT TAG LABEL [TAG LABEL ...]: one choice, VAR = its TAG.
# Plain prompt: a number, a TAG, or Enter for DEFAULT (when set).
ui_menu() {
  local __var=$1 text=$2 def=$3; shift 3
  local tags=() labels=() args=() i iw=0 ans def_idx=''
  while (($#)); do tags+=("$1"); labels+=("${2:-$1}"); shift 2; done
  for i in "${!tags[@]}"; do
    args+=("${tags[i]}" "${labels[i]}")
    ((${#labels[i]} <= iw)) || iw=${#labels[i]}
    [[ ${tags[i]} != "$def" ]] || def_idx=$((i + 1))
  done
  if [[ $UI == whiptail ]]; then ui_screen_on
    ui_size "$text" "${#tags[@]}" "$iw"
    ui_fit_labels args $((UI_W - 10)) 2
    ans=$(wt --notags ${def_idx:+--default-item "$def"} --menu "$text" "$UI_H" "$UI_W" "$UI_L" "${args[@]}") || ui_cancelled
    printf -v "$__var" '%s' "$ans"
    return 0
  fi
  printf '\n%s\n' "$text" >&2
  for i in "${!tags[@]}"; do printf '  %2d) %s\n' $((i + 1)) "${labels[i]}" >&2; done
  while true; do
    read -rp "${def_idx:+[$def_idx] }> " ans || die "Input closed"
    ans=$(ui_trim "$ans")
    if [[ -z $ans && -n $def_idx ]]; then ans=$def_idx; fi
    if [[ $ans =~ ^[0-9]+$ ]] && ((ans >= 1 && ans <= ${#tags[@]})); then
      printf -v "$__var" '%s' "${tags[ans-1]}"; return 0
    fi
    for i in "${!tags[@]}"; do
      if [[ -n $ans && ($ans == "${tags[i]}" || $ans == "${labels[i]}") ]]; then
        printf -v "$__var" '%s' "${tags[i]}"; return 0
      fi
    done
    warn "Enter a number between 1 and ${#tags[@]}"
  done
}

# ui_checklist VAR TEXT TAG LABEL on|off [...]: several choices, VAR = their TAGs separated by spaces
ui_checklist() {
  local __var=$1 text=$2; shift 2
  local tags=() labels=() states=() args=() i iw=0 ans n picked=()
  while (($#)); do tags+=("$1"); labels+=("$2"); states+=("$3"); shift 3; done
  for i in "${!tags[@]}"; do
    args+=("${tags[i]}" "${labels[i]}" "$( [[ ${states[i]} == on ]] && echo ON || echo OFF)")
    ((${#labels[i]} + 4 <= iw)) || iw=$((${#labels[i]} + 4))
  done
  if [[ $UI == whiptail ]]; then ui_screen_on
    ui_size "$text"$'\n'"(Space ticks or unticks, Enter confirms)" "${#tags[@]}" "$iw"
    ui_fit_labels args $((UI_W - 14)) 3
    ans=$(wt --notags --separate-output --checklist "$text"$'\n'"(Space ticks or unticks, Enter confirms)" \
          "$UI_H" "$UI_W" "$UI_L" "${args[@]}") || ui_cancelled
    printf -v "$__var" '%s' "$(tr '\n' ' ' <<< "$ans" | xargs)"
    return 0
  fi
  printf '\n%s\n' "$text" >&2
  for i in "${!tags[@]}"; do
    printf '  %2d) [%s] %s\n' $((i + 1)) "$( [[ ${states[i]} == on ]] && echo x || echo ' ')" "${labels[i]}" >&2
  done
  while true; do
    read -rp "Numbers separated by spaces (Enter = the ticked ones, 0 = none): " ans || die "Input closed"
    picked=()
    if [[ -z $(ui_trim "$ans") ]]; then
      for i in "${!tags[@]}"; do [[ ${states[i]} != on ]] || picked+=("${tags[i]}"); done
    elif [[ $(ui_trim "$ans") != 0 ]]; then
      for n in ${ans//,/ }; do
        if [[ $n =~ ^[0-9]+$ ]] && ((n >= 1 && n <= ${#tags[@]})); then
          [[ " ${picked[*]} " == *" ${tags[n-1]} "* ]] || picked+=("${tags[n-1]}")
        else
          warn "Ignored '$n' (not between 1 and ${#tags[@]})"
        fi
      done
    fi
    printf -v "$__var" '%s' "${picked[*]}"
    return 0
  done
}

# ui_input VAR LABEL [DEFAULT] [CHECK] [HELP]: one line of text; empty = DEFAULT. CHECK is a function
# that gets the answer and prints why it is wrong (non-zero exit), then the question is asked again.
ui_input() {
  local __var=$1 label=$2 def=${3:-} check=${4:-} help=${5:-} ans err shown=0
  while true; do
    if [[ $UI == whiptail ]]; then ui_screen_on
      ui_size "${help:+$help$'\n\n'}$label"
      ans=$(wt --inputbox "${help:+$help$'\n\n'}$label" "$UI_H" "$UI_W" "$def") || ui_cancelled
    else
      ((shown)) || [[ -z $help ]] || printf '\n%s\n' "$help" >&2
      shown=1
      read -rp "$label${def:+ [$def]}: " ans || die "Input closed"
    fi
    # Pasted text can carry invisible characters (bracketed-paste markers, non-breaking or zero-width
    # spaces) in front of it, and "/home/x" would then no longer start with "/".
    ans=${ans//$'\e[200~'/}; ans=${ans//$'\e[201~'/}
    ans=${ans//[$'   ']/ }; ans=${ans//[$'​‌‍⁠﻿']/}; ans=${ans//[[:cntrl:]]/}
    ans=$(ui_trim "$ans"); ans=${ans:-$def}
    if [[ -n $check ]] && ! err=$("$check" "$ans"); then ui_error "$err"; continue; fi
    printf -v "$__var" '%s' "$ans"
    return 0
  done
}

# ui_secret VAR LABEL [HELP]: hidden input (passwords, webhook URLs)
ui_secret() {
  local __var=$1 label=$2 help=${3:-} ans
  if [[ $UI == whiptail ]]; then ui_screen_on
    ui_size "${help:+$help$'\n\n'}$label"
    ans=$(wt --passwordbox "${help:+$help$'\n\n'}$label" "$UI_H" "$UI_W") || ui_cancelled
  else
    [[ -z $help ]] || printf '\n%s\n' "$help" >&2
    read -rsp "$label: " ans || die "Input closed"
    printf '\n' >&2
  fi
  printf -v "$__var" '%s' "$ans"
}

# ui_yesno TEXT [DEFAULT yes|no]: exit 0 for yes
ui_yesno() {
  local text=$1 def=${2:-no} ans rc=0
  if [[ $UI == whiptail ]]; then ui_screen_on
    ui_size "$text"
    wt $( [[ $def == no ]] && echo --defaultno) --yesno "$text" "$UI_H" "$UI_W" || rc=$?
    ((rc != 255)) || ui_cancelled
    return "$rc"
  fi
  while true; do
    read -rp "$text [$def]: " ans || die "Input closed"
    ans=$(ui_trim "${ans:-$def}")
    if [[ $ans =~ ^[Yy]([Ee][Ss])?$ ]]; then return 0; fi
    if [[ $ans =~ ^[Nn][Oo]?$ ]]; then return 1; fi
    warn "Please answer yes or no"
  done
}

# choose VAR PROMPT OPTION...: VAR set already (a flag) is checked against the options; else asked.
choose() {
  local __var=$1 prompt=$2; shift 2
  local opts=("$@") cur=${!__var:-} o args=()
  if [[ -n $cur ]]; then
    for o in "${opts[@]}"; do [[ $o == "$cur" ]] && return 0; done
    die "Invalid value '$cur' for $__var (valid: ${opts[*]})"
  fi
  ((${#opts[@]} > 0)) || die "No options available for: $prompt"
  interactive || die "Non-interactive deploy requires setting $__var (options: ${opts[*]})"
  for o in "${opts[@]}"; do args+=("$o" "$o"); done
  ui_menu "$__var" "$prompt" '' "${args[@]}"
}

cleanup() {
  ui_screen_off
  if [[ -n $TMP_DIR && -d $TMP_DIR ]]; then rm -rf "$TMP_DIR"; fi
  # a menu task (cmd_menu runs each one in a subshell) keeps the menu's terminal setup for the next one
  if ((! MENU_TASK)) && [[ -n $UI_TERMINFO && -d $UI_TERMINFO ]]; then rm -rf "$UI_TERMINFO"; fi
  return 0
}
MENU_TASK=0
trap cleanup EXIT
# Ctrl-C, kill or a dropped SSH session must run the cleanup too: otherwise the ssh-agent (holding the
# deploy key) and the target lock outlive the run.
trap 'exit 130' INT; trap 'exit 143' TERM; trap 'exit 129' HUP

# without_lock CMD...: runs CMD with the target lock descriptor closed, so long-lived children
# (ssh-agent, the SSH control master) cannot keep the lock after this run ends.
without_lock() {
  if [[ -n ${LOCK_FD:-} ]]; then "$@" {LOCK_FD}>&-; else "$@"; fi
}

# ---------------------------------------------------------------- state initialization
ensure_state_files() {
  mkdir -p "$DATA/logs" "$DATA/.locks"
  chmod 0700 "$DATA" "$DATA/.locks" 2>/dev/null || true
  if [[ ! -f $SITES_JSON ]]; then
    printf '{"sites":{}}\n' > "$SITES_JSON"
    chmod 0644 "$SITES_JSON" 2>/dev/null || chmod 0600 "$SITES_JSON"
  fi
  if [[ ! -f $TARGETS_JSON ]]; then
    printf '{"targets":{}}\n' > "$TARGETS_JSON"
    chmod 0644 "$TARGETS_JSON" 2>/dev/null || chmod 0600 "$TARGETS_JSON"
  fi
}

# ---------------------------------------------------------------- pure function computations
compute_slug() {
  printf '%s' "$1" | tr '.' '-'
}

compute_linux_user() {
  local d="$1" u sha
  u=$(printf '%s' "$d" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/_/g')
  if [[ $u =~ ^[0-9] ]]; then
    u="s_$u"
  fi
  if ((${#u} > 32)); then
    sha=$(printf '%s' "$d" | sha1sum | cut -c1-6)
    u="${u:0:24}_${sha}"
  fi
  printf '%s' "$u"
}

sanitize_domain() {
  local in="$1"
  in=$(echo "$in" | xargs)
  in=${in#http://}
  in=${in#https://}
  in=${in%%/*}
  in=${in%%\?*}
  in=${in%%:*}
  in=$(echo "$in" | tr '[:upper:]' '[:lower:]')
  if [[ $in == www.* ]]; then
    in=${in#www.}
  fi
  printf '%s' "$in"
}

validate_hostname() {
  local h="$1"
  if [[ ${#h} -gt 253 ]]; then return 1; fi
  if [[ ! $h =~ ^([a-z0-9]([a-z0-9-]*[a-z0-9])?\.)+[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]]; then
    return 1
  fi
  return 0
}

# ---------------------------------------------------------------- sites.json helpers
site_exists() { jq -e --arg s "$1" '.sites | has($s)' "$SITES_JSON" >/dev/null 2>&1; }
site_field()  { jq -r --arg s "$1" --arg f "$2" '.sites[$s] | getpath($f | split(".")) // empty' "$SITES_JSON"; }
sites_list()  { jq -r '.sites | keys[]' "$SITES_JSON" 2>/dev/null | sort; }

save_site_to_json() {
  local domain="$1" site_obj="$2"
  local tmp_file="$DATA/sites.tmp.$$"
  local bak_file="$DATA/sites.json.bak"

  if [[ ! -f $SITES_JSON ]]; then
    printf '{"sites":{}}\n' > "$SITES_JSON"
  fi
  cp -p "$SITES_JSON" "$bak_file" 2>/dev/null || true

  (
    umask 077
    jq --arg d "$domain" --argjson s "$site_obj" \
      '.sites[$d] = $s' "$SITES_JSON" > "$tmp_file"
    if ! jq empty "$tmp_file" >/dev/null 2>&1; then
      rm -f "$tmp_file"
      die "Failed to validate updated JSON structure for $SITES_JSON"
    fi
    chmod 0644 "$tmp_file" 2>/dev/null || chmod 0600 "$tmp_file"
    mv -f "$tmp_file" "$SITES_JSON"
  )
}

update_site_db_block() {
  local domain="$1" host="$2" port="$3" name="$4" user="$5"
  local cur_site db_json new_site
  cur_site=$(jq -c --arg d "$domain" '.sites[$d]' "$SITES_JSON")
  db_json=$(jq -n --arg h "$host" --argjson p "$port" --arg n "$name" --arg u "$user" \
    '{host: $h, port: $p, name: $n, user: $u}')
  new_site=$(jq -n --argjson s "$cur_site" --argjson db "$db_json" '$s + {db: (($s.db // {}) + $db)}')
  save_site_to_json "$domain" "$new_site"
}

update_site_field() {
  local domain="$1" field="$2" val="$3"
  local cur_site new_site
  cur_site=$(jq -c --arg d "$domain" '.sites[$d]' "$SITES_JSON")
  if [[ "$field" == *.* ]]; then
    local p1="${field%%.*}" p2="${field#*.}"
    new_site=$(jq -n --argjson s "$cur_site" --arg p1 "$p1" --arg p2 "$p2" --arg val "$val" '
      $s + {($p1): (($s[$p1] // {}) + {($p2): $val})}
    ')
  else
    new_site=$(jq -n --argjson s "$cur_site" --arg f "$field" --arg val "$val" '
      $s + {($f): $val}
    ')
  fi
  save_site_to_json "$domain" "$new_site"
}

# Records the TLS choice of this run (TLS_MODE and its paths) in sites.json.
# A pasted certificate now lives on the target, so it is remembered as "existing".
update_site_tls_block() {
  local domain="$1" mode="$2"
  local cur_site tls_json new_site
  cur_site=$(jq -c --arg d "$domain" '.sites[$d]' "$SITES_JSON")
  case "$mode" in
    files)
      tls_json=$(jq -n --arg c "$CERT_FILE" --arg k "$KEY_FILE" \
        '{mode: "files", cert_file: $c, key_file: $k}') ;;
    existing)
      tls_json=$(jq -n --arg c "$TLS_CERT_PATH" --arg k "$TLS_KEY_PATH" \
        '{mode: "existing", cert_path: $c, key_path: $k}') ;;
    paste)
      tls_json=$(jq -n --arg c "$TLS_TARGET_DIR/$domain/certificate.crt" --arg k "$TLS_TARGET_DIR/$domain/privatekey.key" \
        '{mode: "existing", cert_path: $c, key_path: $k}') ;;
    certbot)
      tls_json=$(jq -n --arg e "$CERTBOT_EMAIL" '{mode: "certbot", email: $e}') ;;
    *)
      tls_json=$(jq -n --arg m "$mode" '{mode: $m}') ;;
  esac
  new_site=$(jq -n --argjson s "$cur_site" --argjson t "$tls_json" '$s + {tls: $t}')
  save_site_to_json "$domain" "$new_site"
}

# ---------------------------------------------------------------- validation
validate_traffic_json() {
  local errors=()
  [[ -f $TRAFFIC_JSON ]] || die "traffic.json not found at $TRAFFIC_JSON"
  if ! jq empty "$TRAFFIC_JSON" >/dev/null 2>&1; then
    die "traffic.json contains invalid JSON syntax"
  fi

  local py_out
  py_out=$(python3 - "$TRAFFIC_JSON" << 'EOF'
import json, sys
traffic_file = sys.argv[1]
with open(traffic_file) as f:
    data = json.load(f)
if not isinstance(data, dict) or len(data) == 0:
    print("ERROR:traffic.json must be a non-empty object")
    sys.exit(0)
for level, cfg in data.items():
    if not isinstance(cfg, dict):
        print(f"ERROR:{level}: level configuration must be an object")
        continue
    pm = cfg.get("pm")
    if pm not in ["ondemand", "dynamic", "static"]:
        print(f"ERROR:{level}: pm must be 'ondemand', 'dynamic', or 'static'")
    max_c = cfg.get("max_children")
    if max_c is None or not isinstance(max_c, int) or max_c <= 0:
        print(f"ERROR:{level}: max_children is required and must be a positive integer")
    if pm == "dynamic":
        for req in ["start_servers", "min_spare", "max_spare"]:
            v = cfg.get(req)
            if v is None or not isinstance(v, int) or v <= 0:
                print(f"ERROR:{level}: {req} is required for dynamic pm and must be a positive integer")
EOF
)
  if [[ -n $py_out ]]; then
    while IFS= read -r line; do
      if [[ $line == ERROR:* ]]; then
        errors+=("${line#ERROR:}")
      fi
    done <<< "$py_out"
  fi

  if ((${#errors[@]} > 0)); then
    printf '%straffic.json validation failed with %d error(s):%s\n' "$C_RED" "${#errors[@]}" "$C_OFF" >&2
    for err in "${errors[@]}"; do printf '  - %s\n' "$err" >&2; done
    return 1
  fi
  return 0
}

validate_sites_json() {
  local target_site="${1:-}"
  local errors=()

  validate_traffic_json || return 1
  [[ -f $SITES_JSON ]] || die "sites.json not found at $SITES_JSON"
  jq -e '.sites | type == "object"' "$SITES_JSON" >/dev/null 2>&1 \
    || die "sites.json missing or invalid (needs a top-level \"sites\" object)"

  local py_out
  py_out=$(python3 - "$SITES_JSON" "$TRAFFIC_JSON" << 'EOF'
import json, sys, re, os

sites_file = sys.argv[1]
traffic_file = sys.argv[2]
try:
    with open(sites_file) as f:
        data = json.load(f)
    with open(traffic_file) as f:
        traffic_data = json.load(f)
except Exception as e:
    print(f"ERROR:Failed to parse JSON: {e}")
    sys.exit(0)

sites = data.get("sites", {})
if not isinstance(sites, dict):
    print("ERROR:Top-level 'sites' must be an object")
    sys.exit(0)

valid_traffic_keys = list(traffic_data.keys())
valid_php = ["8.0", "8.1", "8.2", "8.3", "8.4"]
user_map = {}

def compute_user(d):
    u = re.sub(r'[^a-z0-9]', '_', d.lower())
    if re.match(r'^[0-9]', u):
        u = "s_" + u
    if len(u) > 32:
        import hashlib
        sha = hashlib.sha1(d.encode('utf-8')).hexdigest()[:6]
        u = u[:24] + "_" + sha
    return u

for domain, s in sites.items():
    if not isinstance(s, dict):
        print(f"ERROR:{domain}: site configuration must be an object")
        continue

    repo = s.get("repo")
    if not repo or not isinstance(repo, str):
        print(f"ERROR:{domain}: repo is required and must be a non-empty string")

    tr = s.get("traffic")
    if tr is not None and tr not in valid_traffic_keys:
        print(f"ERROR:{domain}: traffic '{tr}' is invalid (valid: {', '.join(valid_traffic_keys)})")

    php = s.get("php_version")
    if php is not None and str(php) not in valid_php:
        print(f"ERROR:{domain}: php_version '{php}' is invalid (valid: {', '.join(valid_php)})")

    tls = s.get("tls")
    if tls is not None:
        if not isinstance(tls, dict):
            print(f"ERROR:{domain}: tls must be an object")
        else:
            m = tls.get("mode")
            if m not in ["none", "existing", "certbot", "files", "keep"]:
                print(f"ERROR:{domain}: tls.mode must be 'none', 'existing', 'certbot', 'files', or 'keep'")
            elif m == "existing":
                for k in ["cert_path", "key_path"]:
                    v = tls.get(k)
                    if v is not None and (not isinstance(v, str) or not v.startswith("/")):
                        print(f"ERROR:{domain}: tls.{k} must be an absolute path on the target")
            elif m == "certbot":
                e = tls.get("email") or ""
                if e and not re.match(r"^[^@\s]+@[^@\s]+\.[^@\s]+$", e):
                    print(f"ERROR:{domain}: tls.email '{e}' is not a valid email address")

    db = s.get("db")
    if db is not None:
        if not isinstance(db, dict):
            print(f"ERROR:{domain}: db must be an object")
        else:
            port = db.get("port")
            if port is not None and not isinstance(port, int):
                print(f"ERROR:{domain}: db.port must be a number")

    sch = s.get("scheduler")
    if sch is not None and not isinstance(sch, bool):
        print(f"ERROR:{domain}: scheduler must be true or false")

    u = compute_user(domain)
    user_map.setdefault(u, []).append(domain)

for u, doms in user_map.items():
    if len(doms) > 1:
        print(f"ERROR:duplicate computed linux_user '{u}': used by {' and '.join(doms)}")
EOF
)

  if [[ -n $py_out ]]; then
    while IFS= read -r line; do
      if [[ $line == WARN:* ]]; then
        warn "${line#WARN:}"
      elif [[ $line == ERROR:* ]]; then
        errors+=("${line#ERROR:}")
      fi
    done <<< "$py_out"
  fi

  # Check filesystem constraints for sites
  local check_sites=()
  if [[ -n $target_site ]]; then
    check_sites=("$target_site")
  else
    while IFS= read -r s; do [[ -n $s ]] && check_sites+=("$s"); done < <(sites_list)
  fi

  for s in "${check_sites[@]}"; do
    if site_exists "$s"; then
      local key_path perms
      key_path=$(site_field "$s" deploy_key)
      if [[ -n $key_path ]]; then
        if [[ ! -f $key_path ]]; then
          errors+=("$s: deploy_key file not found ($key_path)")
        else
          perms=$(stat -c %a "$key_path" 2>/dev/null || echo "")
          if [[ $perms != 600 && $perms != 400 ]]; then
            errors+=("$s: deploy_key $key_path must be chmod 600 or 400 (is $perms)")
          fi
        fi
      fi
      local t_mode
      t_mode=$(site_field "$s" tls.mode)
      if [[ $t_mode == "files" ]]; then
        local cfile kfile
        cfile=$(site_field "$s" tls.cert_file)
        kfile=$(site_field "$s" tls.key_file)
        if [[ -z $cfile || ! -f $cfile ]]; then
          errors+=("$s: tls.cert_file not found ($cfile)")
        elif ! openssl x509 -in "$cfile" -noout -checkend 0 >/dev/null 2>&1; then
          errors+=("$s: certificate in $cfile is expired or invalid")
        fi
        if [[ -z $kfile || ! -f $kfile ]]; then
          errors+=("$s: tls.key_file not found ($kfile)")
        fi
        if [[ -f $cfile && -f $kfile ]]; then
          local c_pub k_pub
          c_pub=$(openssl x509 -in "$cfile" -noout -pubkey 2>/dev/null | openssl pkey -pubin -outform DER 2>/dev/null | sha256sum | awk '{print $1}' || echo "c")
          k_pub=$(openssl pkey -in "$kfile" -pubout -outform DER 2>/dev/null | sha256sum | awk '{print $1}' || echo "k")
          if [[ "$c_pub" != "$k_pub" ]]; then
            errors+=("$s: certificate $cfile does not match private key $kfile")
          fi
        fi
      fi
    fi
  done

  if ((${#errors[@]} > 0)); then
    printf '%sValidation failed with %d error(s):%s\n' "$C_RED" "${#errors[@]}" "$C_OFF" >&2
    for err in "${errors[@]}"; do printf '  - %s\n' "$err" >&2; done
    return 1
  fi
  return 0
}

# ---------------------------------------------------------------- setups
setups_list() { grep -v -e '^[[:space:]]*#' -e '^[[:space:]]*$' "$SETUPS_FILE" | cut -d'|' -f1; }
cmd_list_setups() { grep -v -e '^[[:space:]]*#' -e '^[[:space:]]*$' "$SETUPS_FILE" | awk -F'|' '{printf "%-26s %s\n", $1, $2}'; }

pick_setup() {
  local all=() args=() name desc
  while IFS='|' read -r name desc; do
    all+=("$name"); args+=("$name" "$(printf '%-13s %s' "$name" "$desc")")
  done < <(grep -v -e '^[[:space:]]*#' -e '^[[:space:]]*$' "$SETUPS_FILE")
  if [[ -n $SETUP ]]; then
    [[ " ${all[*]} " == *" $SETUP "* ]] || die "Invalid setup '$SETUP' (valid: ${all[*]})"
    return 0
  fi
  if ! interactive; then
    # -y without --setup: the setup the target runs already (its marker)
    [[ -n $TARGET_MARKER && " ${all[*]} " == *" $TARGET_MARKER "* ]] || die "Non-interactive deploy requires --setup (options: ${all[*]})"
    SETUP=$TARGET_MARKER; return 0
  fi
  local i
  for ((i = 1; i < ${#args[@]}; i += 2)); do
    [[ ${args[i-1]} != "$TARGET_MARKER" ]] || args[i]+="  (current)"
  done
  ui_menu SETUP "Setup on $TARGET_LABEL:" "$TARGET_MARKER" "${args[@]}"
}

# ---------------------------------------------------------------- targets
check_dest() {
  [[ $1 =~ ^[A-Za-z0-9._-]+@[A-Za-z0-9._-]+(:[0-9]+)?$ ]] && return 0
  echo "Use user@host or user@host:port (e.g. deploy@203.0.113.10)"; return 1
}
parse_dest() {
  [[ $1 =~ ^([A-Za-z0-9._-]+)@([A-Za-z0-9._-]+)(:([0-9]+))?$ ]] || die "Bad target '$1' (use user@host[:port])"
  P_USER=${BASH_REMATCH[1]}; P_HOST=${BASH_REMATCH[2]}; P_PORT=${BASH_REMATCH[4]:-22}
}

check_local_sudo() {
  if [[ $(id -u) -eq 0 ]]; then return 0; fi
  if ! sudo -n true 2>/dev/null; then
    if ((! ASK_BECOME)); then
      die "Deploying to 'this machine' requires root rights. Passwordless sudo is not configured for user '$CURRENT_USER'. Either configure passwordless sudo in /etc/sudoers or pass --ask-become to prompt for your sudo password."
    fi
  fi
}

pick_target() {
  local hname
  hname=$(hostname -s 2>/dev/null || hostname || echo "localhost")

  if [[ $TARGET == "local" ]]; then TARGET="this"; fi

  if [[ -z $TARGET ]]; then
    interactive || die "Non-interactive deploy requires --target this|NAME|user@host[:port]"
    local args=(this "This machine ($hname)") k h
    if [[ -f $TARGETS_JSON ]]; then
      while IFS=$'\t' read -r k h; do
        [[ -n $k ]] && args+=("$k" "$k ($h)")
      done < <(jq -r '.targets | to_entries[] | "\(.key)\t\(.value.user)@\(.value.host)"' "$TARGETS_JSON" 2>/dev/null || true)
    fi
    args+=(__new "Another machine (enter user@host)")
    ui_menu TARGET "${UI_ASK_WHERE:-Deploy where?}" '' "${args[@]}"
    if [[ $TARGET == __new ]]; then
      ui_input TARGET "Target machine (user@host or user@host:port)" '' check_dest
    fi
  fi

  if [[ $TARGET == "this" ]]; then
    TARGET_LABEL="This machine ($hname)"
    TARGET_CONN="local"
    TARGET_HOST="localhost"
    TARGET_USER="$CURRENT_USER"
    TARGET_PORT=22
    TARGET_KEY="local"
    ((! NEED_ROOT)) || check_local_sudo
    return 0
  fi

  if [[ -f $TARGETS_JSON ]] && jq -e --arg t "$TARGET" '.targets | has($t)' "$TARGETS_JSON" >/dev/null 2>&1; then
    TARGET_LABEL="$TARGET ($(jq -r --arg t "$TARGET" '.targets[$t].host' "$TARGETS_JSON"))"
    TARGET_CONN="ssh"
    TARGET_HOST=$(jq -r --arg t "$TARGET" '.targets[$t].host' "$TARGETS_JSON")
    TARGET_USER=$(jq -r --arg t "$TARGET" '.targets[$t].user' "$TARGETS_JSON")
    TARGET_PORT=$(jq -r --arg t "$TARGET" '.targets[$t].port // 22' "$TARGETS_JSON")
    TARGET_KEY="$TARGET"
    return 0
  fi

  parse_dest "$TARGET"
  TARGET_LABEL="$TARGET"
  TARGET_CONN="ssh"
  TARGET_HOST="$P_HOST"
  TARGET_USER="$P_USER"
  TARGET_PORT="$P_PORT"
  TARGET_KEY="${P_USER}@${P_HOST}:${P_PORT}"
}

# Reads the target's state (setup marker, its sites, docker stack settings) before any question about it
probe_target() {
  info "Checking target machine state..."
  local probe_json=''
  local probe_py='import json, os, glob, re, subprocess
res = {"marker": "", "sites": [], "foreign_vhosts": [], "foreign_containers": [],
       "stack": {"configured": False, "settings": {}, "legacy": os.path.exists("/opt/php-stack/docker-compose.yaml") and not os.path.exists("/opt/php-stack/REPLACED-BY-docker-stack.txt")}}
try:
    with open("/opt/docker-stack/.deployer-stack.json") as f:
        res["stack"]["settings"] = json.load(f)
    res["stack"]["configured"] = True
except Exception: pass
if os.path.exists("/etc/deployer/setup"):
    try:
        with open("/etc/deployer/setup") as f: res["marker"] = f.read().strip()
    except Exception: pass

recorded = {}
for sf in glob.glob("/etc/deployer/sites/*.json"):
    try:
        with open(sf) as f:
            d = json.load(f)
            dom_name = d.get("domain", os.path.basename(sf)[:-5])
            recorded[dom_name] = d
    except Exception: pass

all_doms = set(recorded.keys())
if os.path.exists("/etc/deployer/redis-dbs"):
    try:
        with open("/etc/deployer/redis-dbs") as f:
            for line in f:
                for p in line.strip().split():
                    if "." in p: all_doms.add(p)
    except Exception: pass

for d in glob.glob("/var/www/html/*"):
    b = os.path.basename(d)
    if "." in b and not b.endswith(".html") and "_" not in b and "-" not in b:
        all_doms.add(b)

try:
    ps = subprocess.check_output(["docker", "ps", "--format", "{{.Names}}"], text=True, stderr=subprocess.DEVNULL)
    for c in ps.split():
        for d in glob.glob("/var/www/html/*"):
            b = os.path.basename(d)
            if "." not in b or "_" in b: continue
            if c.startswith("php-") and re.sub(r"[^a-z0-9]", "-", b.lower()) == c[4:]:
                all_doms.add(b)
            if c.endswith("-php") and os.path.exists(f"{d}/docker-compose.yml") and re.sub(r"[^a-z0-9]", "-", b.lower()) in c:
                all_doms.add(b)
except Exception: pass

for dom in sorted(all_doms):
    if dom in recorded:
        if recorded[dom].get("status") != "stopped":
            res["sites"].append(recorded[dom])
        continue
    s_info = {"domain": dom, "setup": res["marker"] or "docker_stack", "project_folder": f"/var/www/html/{dom}"}
    try:
        with open("/etc/passwd") as f:
            for l in f:
                parts = l.strip().split(":")
                if f"deployer-managed-{dom}" in l or f"deployer-managed:{dom}" in l or f"deployer-managed={dom}" in l:
                    s_info["linux_user"] = parts[0]
                    s_info["uid"] = int(parts[2])
                    s_info["gid"] = int(parts[3])
                    break
    except Exception: pass
    vhost = f"/etc/nginx/sites-available/{dom}.conf"
    php_ver, tls_mode, traffic = "8.2", "none", "medium"
    if os.path.exists(vhost):
        try:
            with open(vhost) as f:
                vc = f.read()
                m = re.search(r"php([0-9]+\.[0-9]+)-fpm\.sock", vc)
                if m: php_ver = m.group(1)
                if "ssl_certificate" in vc and not vc.strip().startswith("#"): tls_mode = "keep"
                tm = re.search(r"\(traffic:\s*([a-zA-Z0-9_-]+)\)", vc)
                if tm: traffic = tm.group(1)
        except Exception: pass
    for dock_comp in (f"/var/www/html/{dom}/docker-compose.yml", f"/var/www/html/{dom}/docker/docker-compose.yaml"):
        if os.path.exists(dock_comp):
            try:
                with open(dock_comp) as f:
                    m = re.search(r"(?:lh-php|enzipe/php-fpm):([0-9]+\.[0-9]+)", f.read())
                    if m: php_ver = m.group(1)
            except Exception: pass
    s_info["php_version"], s_info["tls_mode"], s_info["traffic"] = php_ver, tls_mode, traffic
    s_info["environment"] = "local"
    res["sites"].append(s_info)

import shutil
res["installed"] = {"nginx": os.path.exists("/usr/sbin/nginx"), "redis": os.path.exists("/usr/bin/redis-server"),
                    "mariadb": os.path.exists("/usr/sbin/mariadbd"), "certbot": shutil.which("certbot") is not None,
                    "mysql": os.path.exists("/usr/sbin/mysqld") and not os.path.exists("/usr/sbin/mariadbd"),
                    "php": sorted(set(re.sub(r"^/usr/sbin/php-fpm", "", f) for f in glob.glob("/usr/sbin/php-fpm[0-9]*")))}

# part states for deploy.sh server: on (installed, enabled), off (installed, disabled), absent
def unit_on(u):
    try: return subprocess.call(["systemctl", "is-enabled", "--quiet", u], stderr=subprocess.DEVNULL) == 0
    except Exception: return False
def part_st(binp, unit):
    if not binp or not os.path.exists(binp): return "absent"
    return "on" if unit_on(unit) else "off"
parts = {"nginx": part_st("/usr/sbin/nginx", "nginx"), "redis": part_st("/usr/bin/redis-server", "redis-server"),
         "mariadb": part_st("/usr/sbin/mariadbd", "mariadb"),
         "mysql": "absent" if os.path.exists("/usr/sbin/mariadbd") else part_st("/usr/sbin/mysqld", "mysql"),
         "certbot": part_st(shutil.which("certbot") or "", "certbot.timer"),
         "clickhouse": part_st("/usr/bin/clickhouse-server", "clickhouse-server"),
         "node": "on" if os.path.exists("/usr/bin/node") else "absent", "second-db": "absent", "stack-mariadb": "absent"}
second_kind = ""
try:
    with open("/opt/deployer-second-db/docker-compose.yml") as f:
        m = re.search(r"^    image: (mysql|mariadb):", f.read(), re.M)
        if m: second_kind = m.group(1)
except Exception: pass
try:
    ps = subprocess.check_output(["docker", "ps", "-a", "--format", "{{.Names}} {{.State}}"], text=True, stderr=subprocess.DEVNULL)
    for l in ps.splitlines():
        n, _, stt = l.partition(" ")
        m = re.match(r"^deployer-(mysql|mariadb)-3307$", n)
        if m:
            second_kind = m.group(1)
            parts["second-db"] = "on" if stt == "running" else "off"
        if n == "enzipe-mariadb": parts["stack-mariadb"] = "on" if stt == "running" else "off"
except Exception: pass
res["parts"] = parts
res["php_states"] = {v: part_st("/usr/sbin/php-fpm" + v, "php" + v + "-fpm") for v in res["installed"]["php"]}
res["second_db_kind"] = second_kind

managed = set()
try:
    with open("/etc/deployer/managed-files") as f: managed = set(l.strip() for l in f)
except Exception: pass
for vf in glob.glob("/etc/nginx/sites-enabled/*"):
    if os.path.basename(vf) == "default": continue
    try:
        with open(vf) as f:
            if "managed by deployer" not in f.read() and os.path.realpath(vf) not in managed: res["foreign_vhosts"].append(vf)
    except Exception: pass

try:
    with open("/etc/deployer/site_user") as f: res["site_user"] = f.read().strip()
except Exception: pass
print(json.dumps(res))'

  if [[ $TARGET_CONN == "local" ]]; then
    probe_json=$(python3 -c "$probe_py" 2>/dev/null) || die "Cannot read target machine state: execution failed."
  else
    probe_json=$(timeout 20 ssh -p "$TARGET_PORT" -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new "$TARGET_USER@$TARGET_HOST" "python3 -c '$probe_py'" 2>/dev/null) \
      || die "Cannot read target '$TARGET_KEY': connection failed or timed out."
  fi

  TARGET_MARKER=$(echo "$probe_json" | jq -r '.marker // empty')
  STACK_CONFIGURED=$(echo "$probe_json" | jq -r 'if .stack.configured then 1 else 0 end')
  STACK_SETTINGS_JSON=$(echo "$probe_json" | jq -c '.stack.settings // {}')
  STACK_LEGACY=$(echo "$probe_json" | jq -r 'if .stack.legacy then 1 else 0 end')
  PROBE_SITES=$(echo "$probe_json" | jq -c '.sites // []')
  SITE_USER_NOW=$(echo "$probe_json" | jq -r '.site_user // empty')
  PROBE_INSTALLED=$(echo "$probe_json" | jq -c '.installed // {}')
  PROBE_PARTS=$(echo "$probe_json" | jq -c '.parts // {}')
  PROBE_PHP_STATES=$(echo "$probe_json" | jq -c '.php_states // {}')
  PROBE_SECOND_KIND=$(echo "$probe_json" | jq -r '.second_db_kind // ""')
  PROBE_FOREIGN_VHOSTS=$(echo "$probe_json" | jq -r '.foreign_vhosts[]?' 2>/dev/null | tr '\n' ' ' | xargs)
}

# After pick_setup: when the target runs the other setup, decide what happens to its sites
handle_switch() {
  local raw_sites=$PROBE_SITES foreign_vhosts=$PROBE_FOREIGN_VHOSTS count
  count=$(echo "$raw_sites" | jq 'length')

  if [[ -z $TARGET_MARKER || $TARGET_MARKER == "$SETUP" ]]; then
    SWITCH_ACTION="none"
    return 0
  fi

  if [[ $TARGET_MARKER == "native_lemp" && -n $foreign_vhosts ]]; then
    die "Refusing switch: foreign Nginx virtual host(s) found in /etc/nginx/sites-enabled: $foreign_vhosts. Stopping Nginx would take non-deployer sites offline. Remove or migrate those virtual hosts first."
  fi

  local bad_php
  bad_php=$(echo "$raw_sites" | jq -r '.[] | select(.php_version as $v | ["8.0","8.1","8.2","8.3","8.4"] | index($v) | not) | .domain + " (" + (.php_version//"?") + ")"' 2>/dev/null | tr '\n' ' ' | xargs)
  if [[ -n $bad_php ]]; then
    die "Refusing switch: site(s) require unsupported PHP version: $bad_php. Supported versions are 8.0, 8.1, 8.2, 8.3, 8.4."
  fi

  OLD_SITES=()
  local d movable=() fixed=() line
  while IFS= read -r d; do [[ -n $d ]] && OLD_SITES+=("$d"); done < <(echo "$raw_sites" | jq -r '.[].domain')
  # A site can be moved when this machine knows how to deploy it: in sites.json with a branch,
  # and for production sites with the saved database settings.
  for d in "${OLD_SITES[@]}"; do
    if site_exists "$d" && [[ -n $(site_field "$d" branch) ]] && \
       { [[ $(echo "$raw_sites" | jq -r --arg d "$d" '.[] | select(.domain == $d) | .environment // "local"') != production ]] || [[ -n $(site_field "$d" db.host) ]]; }; then
      movable+=("$d")
    else
      fixed+=("$d")
    fi
  done

  if [[ -n $SWITCH_ACTION ]]; then
    case "$SWITCH_ACTION" in
      stop|close) SWITCH_ACTION=stop ;;
      move)       SWITCH_ACTION=stop; MOVE_SITES=("${movable[@]}") ;;
      move:*|move=*)
        SWITCH_ACTION=stop
        IFS=, read -ra MOVE_SITES <<< "${CLI_SWITCH#move?}"
        for d in "${MOVE_SITES[@]}"; do
          [[ " ${movable[*]} " == *" $d "* ]] || die "--switch move:...: '$d' cannot be moved (not running on $TARGET_MARKER, or not in this machine's sites.json with a branch)"
        done ;;
      cancel)     info "Switch cancelled. No changes made."; exit 0 ;;
      *)          die "Invalid --switch '$SWITCH_ACTION' (valid: move, move:site1,site2, stop, cancel)" ;;
    esac
  elif ! interactive; then
    die "This server runs $count site(s) on $TARGET_MARKER (${OLD_SITES[*]:-none}). Switching to $SETUP takes them down: --switch move (move all), --switch move:site1,site2, --switch stop (close them) or --switch cancel."
  else
    local text notes='' choice='' picks args=()
    text="This server runs $count site(s) on $TARGET_MARKER:"$'\n'
    while IFS= read -r line; do text+="   $line"$'\n'; done < <(echo "$raw_sites" | jq -r '.[] | "\(.domain)  (PHP \(.php_version // "?"), \(.environment // "local"), \(if (.tls_mode // "none") == "none" then "http" else "https" end))"')
    text+="Both setups need ports 80 and 443, so a server runs one setup at a time. Switching to $SETUP takes ALL of these sites down. What should happen to them?"
    if ((${#fixed[@]})); then notes+=$'\n'"Close only (not in this machine's sites.json with a branch): ${fixed[*]}"; fi
    if [[ $SETUP == docker_stack ]]; then
      local other_php
      other_php=$(echo "$raw_sites" | jq -r '.[] | select((.php_version // "8.2") != "8.2") | .domain' | tr '\n' ' ')
      [[ -z $other_php ]] || notes+=$'\n'"Note: docker_stack runs PHP 8.2 only; moved sites ${other_php}will run on 8.2."
    fi
    while true; do
      ui_menu choice "$text$notes" '' \
        move   "Move all of them to $SETUP (deployed again with their saved settings; local databases are copied, Redis starts empty)" \
        choose "Choose which sites to move (the others are closed)" \
        close  "Close them (offline; nothing is deleted)" \
        cancel "Cancel"
      case "$choice" in
        move)   SWITCH_ACTION=stop; MOVE_SITES=("${movable[@]}"); break ;;
        choose)
          if ((${#movable[@]} == 0)); then ui_error "No site can be moved from this machine."; continue; fi
          args=(); for d in "${movable[@]}"; do args+=("$d" "$d" off); done
          ui_checklist picks "Sites to move to $SETUP (the others are closed):" "${args[@]}"
          SWITCH_ACTION=stop
          read -ra MOVE_SITES <<< "$picks"
          break ;;
        close)  SWITCH_ACTION=stop; break ;;
        cancel) info "Deployment cancelled. No changes made."; exit 0 ;;
      esac
    done
  fi

  SWITCH_SITES_JSON=$(python3 - "$raw_sites" "$TRAFFIC_JSON" << 'EOF'
import sys, json, re

sites = json.loads(sys.argv[1])
traffic_data = json.load(open(sys.argv[2]))

def compute_user(d):
    u = re.sub(r'[^a-z0-9]', '_', d.lower())
    if re.match(r'^[0-9]', u): u = "s_" + u
    if len(u) > 32:
        import hashlib
        u = u[:24] + "_" + hashlib.sha1(d.encode('utf-8')).hexdigest()[:6]
    return u

enriched = []
for i, s in enumerate(sites):
    dom = s["domain"]
    slug = re.sub(r'[^a-z0-9]', '_', dom.lower())
    l_user = s.get("linux_user") or compute_user(dom)
    s_id = s.get("site_id") or (l_user if s.get("linux_user") else compute_user(dom))
    tr_lvl = s.get("traffic") or "medium"
    if tr_lvl not in traffic_data: tr_lvl = "medium"
    php_v = str(s.get("php_version") or "8.2")
    env = s.get("environment") or "local"
    tls = s.get("tls_mode") or "none"
    uid_val = s.get("uid") or l_user
    gid_val = s.get("gid") or l_user
    s_obj = {
        "domain": dom,
        "slug": slug,
        "linux_user": l_user,
        "site_id": s_id,
        "uid": uid_val,
        "gid": gid_val,
        "php_version": php_v,
        "traffic": tr_lvl,
        "traffic_config": traffic_data[tr_lvl],
        "environment": env,
        "tls_mode": tls,
        "project_folder": s.get("project_folder") or f"/var/www/html/{dom}",
        "redis_db_session": s.get("redis_db_session") if s.get("redis_db_session") is not None else i * 2,
        "redis_db_cache": s.get("redis_db_cache") if s.get("redis_db_cache") is not None else (i * 2) + 1
    }
    enriched.append(s_obj)

print(json.dumps(enriched))
EOF
)

  local closed=()
  for d in "${OLD_SITES[@]}"; do [[ " ${MOVE_SITES[*]} " == *" $d "* ]] || closed+=("$d"); done
  SWITCH_SUMMARY="leave $TARGET_MARKER"
  ((${#MOVE_SITES[@]} == 0)) || SWITCH_SUMMARY+="; move to $SETUP: ${MOVE_SITES[*]}"
  ((${#closed[@]} == 0)) || SWITCH_SUMMARY+="; close: ${closed[*]}"
}

cmd_register_target() {
  local dest=${1:-}
  if [[ -z $dest ]]; then
    interactive || die "usage: deploy.sh register-target user@host[:port]"
    ui_input dest "New target machine (user@host or user@host:port; the user needs sudo there)" '' check_dest
  fi
  parse_dest "$dest"
  local pub="${DEPLOY_PUBKEY:-}"
  if [[ -z $pub && -f $HOME/.ssh/id_ed25519.pub ]]; then
    pub="$HOME/.ssh/id_ed25519.pub"
  fi
  if [[ -z $pub || ! -f $pub ]]; then
    mkdir -p "$HOME/.ssh"
    chmod 700 "$HOME/.ssh"
    ssh-keygen -t ed25519 -N "" -f "$HOME/.ssh/id_ed25519" >/dev/null 2>&1 || die "Could not generate deploy key"
    pub="$HOME/.ssh/id_ed25519.pub"
  fi
  local pubkey_content
  pubkey_content=$(cat "$pub")

  ui_screen_off   # ssh may ask for the password of $P_USER in the terminal
  info "Registering target $P_USER@$P_HOST:$P_PORT using public key $pub..."

  if [[ $P_USER == "deployer" ]]; then
    ssh -p "$P_PORT" -o StrictHostKeyChecking=accept-new "$P_USER@$P_HOST" \
      "mkdir -p -m 700 ~/.ssh && echo '$pubkey_content' >> ~/.ssh/authorized_keys && sort -u ~/.ssh/authorized_keys -o ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys"
  else
    info "Bootstrapping 'deployer' user and passwordless sudo on $P_HOST..."
    ssh -p "$P_PORT" -o StrictHostKeyChecking=accept-new "$P_USER@$P_HOST" '
      set -e
      SUDO=""
      if [ "$(id -u)" -ne 0 ]; then SUDO="sudo"; fi
      if ! id deployer >/dev/null 2>&1; then $SUDO useradd -m -s /bin/bash deployer; fi
      echo "deployer ALL=(ALL) NOPASSWD:ALL" | $SUDO tee /etc/sudoers.d/deployer >/dev/null
      $SUDO chmod 0440 /etc/sudoers.d/deployer
      $SUDO mkdir -p -m 700 /home/deployer/.ssh
      $SUDO chown -R deployer:deployer /home/deployer/.ssh
      if ! command -v python3 >/dev/null 2>&1; then
        $SUDO apt-get update -y && $SUDO apt-get install -y python3
      fi
    '
    printf '%s\n' "$pubkey_content" | ssh -p "$P_PORT" -o StrictHostKeyChecking=accept-new "$P_USER@$P_HOST" \
      'SUDO=$( [ "$(id -u)" -eq 0 ] || echo sudo ); $SUDO tee -a /home/deployer/.ssh/authorized_keys >/dev/null && $SUDO sort -u /home/deployer/.ssh/authorized_keys -o /home/deployer/.ssh/authorized_keys && $SUDO chmod 600 /home/deployer/.ssh/authorized_keys && $SUDO chown -R deployer:deployer /home/deployer/.ssh'
  fi

  info "Verifying SSH connection and passwordless sudo for deployer@$P_HOST:$P_PORT..."
  ssh -p "$P_PORT" -o BatchMode=yes -o StrictHostKeyChecking=accept-new deployer@"$P_HOST" "sudo -n whoami" >/dev/null || die "Verification failed for deployer@$P_HOST:$P_PORT"
  info "Target successfully registered and verified: deployer@$P_HOST:$P_PORT"

  # Remember it, so it shows up under "A remote machine" and works as --target <name>
  local name="${REGISTER_NAME:-$P_HOST}" existing tmp
  existing=$(jq -r --arg h "$P_HOST" --argjson p "$P_PORT" \
    '.targets | to_entries[] | select(.value.host == $h and .value.user == "deployer" and ((.value.port // 22) == $p)) | .key' \
    "$TARGETS_JSON" 2>/dev/null | head -1)
  if [[ -n $existing ]]; then
    info "Already in targets.json as '$existing' (use --target $existing)"
  else
    tmp="$DATA/targets.tmp.$$"
    jq --arg n "$name" --arg h "$P_HOST" --argjson p "$P_PORT" \
      '.targets[$n] = {host: $h, user: "deployer", port: $p}' "$TARGETS_JSON" > "$tmp" && mv -f "$tmp" "$TARGETS_JSON"
    chmod 0644 "$TARGETS_JSON" 2>/dev/null || true
    info "Saved in targets.json as '$name' (use --target $name)"
  fi
}

# ---------------------------------------------------------------- add-site wizard
check_domain() {
  local d
  d=$(sanitize_domain "$1")
  [[ -n $d ]] || { echo "Website address cannot be empty"; return 1; }
  validate_hostname "$d" || { echo "'$1' is not a valid website address"; return 1; }
}

check_repo() {
  [[ -n $1 ]] || { echo "Repository URL cannot be empty"; return 1; }
  [[ $1 =~ ^(git@|ssh://|https://|http://) ]] || { echo "Repository URL must begin with git@, ssh://, or https://"; return 1; }
}

# confirm_key_overwrite FILE: returns 0 when FILE does not exist or may be replaced.
confirm_key_overwrite() {
  local f=$1
  [[ -e $f ]] || return 0
  ui_yesno "Key file '$f' already exists. Replace it?" no
}

# paste_deploy_key DEST: asks for the private key and then the public key, checks that they are a pair,
# and saves them as DEST (0600) and DEST.pub until the deploy puts them in the site user's ~/.ssh.
paste_deploy_key() {
  local dest=$1 tmp pub pub_in pub_line
  confirm_key_overwrite "$dest" || return 1
  ui_screen_off   # the key is pasted into the terminal
  mkdir -p "$HOME/.ssh"
  chmod 700 "$HOME/.ssh"
  [[ -n $TMP_DIR ]] || TMP_DIR=$(mktemp -d)
  tmp="$TMP_DIR/pasted-deploy-key"
  while true; do
    printf '\nPaste the PRIVATE key (-----BEGIN OPENSSH PRIVATE KEY----- ... -----END OPENSSH PRIVATE KEY-----).\n' >&2
    printf 'Pasted text is not shown. No need to press Enter: it is read as soon as the END line arrives.\n' >&2
    PEM_PENDING=''
    read_pem KEY "$tmp" 1
    swallow_keys
    printf '\n' >&2
    chmod 600 "$tmp"
    if pub=$(ssh-keygen -y -P "" -f "$tmp" 2>/dev/null); then break; fi
    warn "That is not a valid private key, or it has a passphrase (a key without passphrase is needed). Paste it again."
  done
  while true; do
    printf '\nPaste the PUBLIC key (one line: ssh-rsa AAAA... ), then press Enter.\n' >&2
    IFS= read -r pub_in || die "Input closed"
    pub_line=$(grep -oE '(ssh|ecdsa|sk)-[^ ]+ [A-Za-z0-9+/=]+( [^[:cntrl:]]*)?' <<< "$pub_in" | head -n 1 || true)
    [[ -n $pub_line ]] || { warn "That is not a public key. Paste it again."; continue; }
    if [[ $(awk '{print $1" "$2}' <<< "$pub_line") == "$(awk '{print $1" "$2}' <<< "$pub")" ]]; then break; fi
    warn "This public key does not belong to that private key. Paste it again."
  done
  mv -f "$tmp" "$dest"
  chmod 600 "$dest"
  printf '%s\n' "$pub_line" > "$dest.pub"
  chmod 644 "$dest.pub"
  info "Both keys received. The deploy installs them as ~/.ssh/id_rsa and id_rsa.pub of the site user, and removes this copy ($dest)."
}

# generate_deploy_key DEST DOMAIN: creates a new RSA key pair DEST (0600) and DEST.pub.
generate_deploy_key() {
  local dest=$1 domain=$2
  confirm_key_overwrite "$dest" || return 1
  mkdir -p "$HOME/.ssh"
  chmod 700 "$HOME/.ssh"
  rm -f "$dest" "$dest.pub"
  ssh-keygen -t rsa -b 4096 -N "" -C "deploy-key ${domain}" -f "$dest" >/dev/null || die "Could not generate key"
  chmod 600 "$dest"
  chmod 644 "$dest.pub"
  info "New key created. The deploy installs it as ~/.ssh/id_rsa and id_rsa.pub of the site user, and removes this copy ($dest)."
}

# show_deploy_key REPO PUBFILE INTRO: prints the public key and where to add it on the git host.
show_deploy_key() {
  local repo=$1 pub=$2 intro=$3 where
  case "$repo" in
    *bitbucket.org*) where="Bitbucket: open the repository > Repository settings > Access keys > Add key" ;;
    *github.com*)    where="GitHub: open the repository > Settings > Deploy keys > Add deploy key (leave \"Allow write access\" off)" ;;
    *gitlab*)        where="GitLab: open the project > Settings > Repository > Deploy keys" ;;
    *)               where="your git host, as a read-only deploy (access) key of the repository" ;;
  esac
  KEY_SHOWN=$pub KEY_WHERE=$where
  printf '\n================ DEPLOY KEY (PUBLIC KEY) ================\n' >&2
  cat "$pub" >&2
  printf '=========================================================\n' >&2
  info "$intro in $where"
  info "Public key file: $pub"
}

cmd_add_site() {
  local input_domain="${1:-}"
  local is_edit=0
  local cur_repo='' cur_key='' cur_aliases=''

  local domain=''
  if [[ -n $input_domain ]]; then
    domain=$(sanitize_domain "$input_domain")
    validate_hostname "$domain" || die "Invalid domain name '$input_domain'"
    if site_exists "$domain"; then
      is_edit=1
      info "Editing existing site '$domain' (press Enter to keep current values)"
    fi
  else
    local raw_in=''
    ui_input raw_in "Website address (e.g. example.com)" '' check_domain
    domain=$(sanitize_domain "$raw_in")
    if site_exists "$domain"; then
      info "Site '$domain' already exists in sites.json. Entering edit mode."
      is_edit=1
    fi
  fi

  if ((is_edit)); then
    cur_repo=$(site_field "$domain" repo)
    cur_key=$(site_field "$domain" deploy_key)
    cur_aliases=$(jq -r --arg d "$domain" '.sites[$d].aliases // [] | join(" ")' "$SITES_JSON" 2>/dev/null || true)
  fi

  # Aliases
  local aliases_json="[]"
  local labels
  IFS='.' read -ra labels <<< "$domain"
  if ((${#labels[@]} == 2)); then
    local def_www="yes"
    if ((is_edit)) && [[ $cur_aliases != *"www.$domain"* ]]; then def_www="no"; fi
    if ui_yesno "Also serve www.$domain?" "$def_www"; then aliases_json="[\"www.$domain\"]"; else aliases_json="[]"; fi
  fi

  # Repository URL
  local repo=''
  ui_input repo "Repository URL (git@..., ssh://... or https://...)" "$cur_repo" check_repo

  # Git key (SSH repositories): pasted or generated. It waits in ~/.ssh/<domain>_deploy (0600) until the
  # deploy installs it as the site user's ~/.ssh/id_rsa and id_rsa.pub and removes this copy.
  local deploy_key_path="${cur_key:-}"
  local is_ssh=0
  if [[ $repo =~ ^(git@|ssh://) ]]; then
    is_ssh=1
    local key_dest="$HOME/.ssh/${domain}_deploy"
    local have_key="${cur_key:-}"
    if [[ -z $have_key || ! -f $have_key ]]; then
      have_key=''
      if [[ -f $key_dest ]]; then have_key="$key_dest"; fi
    fi
    local key_choice='' opts=()
    while true; do
      opts=(paste "Paste the private key and the public key" generate "Generate a new key and show it to add to the repository")
      if [[ -n $have_key ]]; then opts=(keep "Keep the waiting key ($have_key)" "${opts[@]}"); fi
      opts+=(server "Use the key already in the site user's ~/.ssh on the server")
      ui_menu key_choice "Git key for the SSH repository (only the site user will have it):" "$( [[ -n $have_key ]] && echo keep || { ((is_edit)) && echo server || echo paste; })" "${opts[@]}"
      case "$key_choice" in
        keep)
          deploy_key_path="$have_key"
          break ;;
        server)
          deploy_key_path=""
          break ;;
        paste)
          if paste_deploy_key "$key_dest"; then
            deploy_key_path="$key_dest"
            show_deploy_key "$repo" "$key_dest.pub" "If this key is not on the repository yet, add its public key"
            break
          fi ;;
        generate)
          if generate_deploy_key "$key_dest" "$domain"; then
            deploy_key_path="$key_dest"
            show_deploy_key "$repo" "$key_dest.pub" "Add this public key"
            break
          fi ;;
      esac
    done
  else
    deploy_key_path=""
  fi

  # Summary of computed values
  local comp_user
  comp_user=$(compute_linux_user "$domain")
  printf '\nSite configuration:\n' >&2
  printf '  Linux user     : %s (or the one user for all sites, chosen at deploy)\n' "$comp_user" >&2
  printf '  Folder         : /var/www/html/%s\n' "$domain" >&2
  printf '  Local database : %s\n' "$comp_user" >&2
  printf '  Redis prefix   : %s_\n' "$comp_user" >&2

  # Pre-save repository check
  if ((is_ssh)) && [[ -n $deploy_key_path ]]; then
    local check_choice='' key_text=''
    [[ -z $KEY_SHOWN ]] || key_text="$(cat "$KEY_SHOWN")"$'\n'"($KEY_WHERE)"$'\n\n'
    ui_menu check_choice "${key_text}Check that the deploy key can read the repository:" check \
      check "Check access now (add the key to the repository first)" \
      skip  "Skip the check"
    if [[ $check_choice != skip ]]; then
      while true; do
        info "Checking repository access to '$repo' (15s timeout)..."
        local ls_err='' rc=0 tmp_err
        tmp_err=$(mktemp)
        GIT_SSH_COMMAND="ssh -i '$deploy_key_path' -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o LogLevel=ERROR" timeout 15 git ls-remote "$repo" HEAD >/dev/null 2>"$tmp_err" || rc=$?
        ls_err=$(cat "$tmp_err")
        rm -f "$tmp_err"
        if ((rc == 0)); then
          info "Repository access verified successfully."
          break
        else
          local retry_yn=''
          ui_menu retry_yn "Repository check failed:"$'\n'"$ls_err" retry \
            retry "Check again" \
            save  "Save the site anyway" \
            stop  "Stop (the site is not saved)"
          if [[ $retry_yn == save ]]; then break; fi
          if [[ $retry_yn == stop ]]; then die "Aborted"; fi
        fi
      done
    fi
  fi

  local site_json
  site_json=$(jq -n \
    --arg repo "$repo" \
    --arg deploy_key "$deploy_key_path" \
    --argjson aliases "$aliases_json" \
    --argjson run_migrations false \
    '{repo: $repo, aliases: $aliases, run_migrations: $run_migrations}
     + (if ($deploy_key | length > 0) then {deploy_key: $deploy_key} else {} end)')

  if ((is_edit)); then
    local prev_b prev_t prev_php prev_tls prev_db prev_env
    prev_b=$(jq -c --arg d "$domain" '.sites[$d].branch // null' "$SITES_JSON")
    prev_t=$(jq -c --arg d "$domain" '.sites[$d].traffic // null' "$SITES_JSON")
    prev_php=$(jq -c --arg d "$domain" '.sites[$d].php_version // null' "$SITES_JSON")
    prev_tls=$(jq -c --arg d "$domain" '.sites[$d].tls // null' "$SITES_JSON")
    prev_db=$(jq -c --arg d "$domain" '.sites[$d].db // null' "$SITES_JSON")
    prev_env=$(jq -c --arg d "$domain" '.sites[$d].env_extra // null' "$SITES_JSON")
    site_json=$(jq -n \
      --argjson cur "$site_json" \
      --argjson branch "$prev_b" \
      --argjson traffic "$prev_t" \
      --argjson php "$prev_php" \
      --argjson tls "$prev_tls" \
      --argjson db "$prev_db" \
      --argjson env "$prev_env" \
      '$cur
       + (if $branch != null then {branch: $branch} else {} end)
       + (if $traffic != null then {traffic: $traffic} else {} end)
       + (if $php != null then {php_version: $php} else {} end)
       + (if $tls != null then {tls: $tls} else {} end)
       + (if $db != null then {db: $db} else {} end)
       + (if $env != null then {env_extra: $env} else {} end)')
  fi

  save_site_to_json "$domain" "$site_json"
  info "Site '$domain' successfully saved to sites.json."
  NEW_SITE_DOMAIN="$domain"
}

# ---------------------------------------------------------------- site selection
pick_site() {
  local all=() opts=() filter=''
  if [[ -n $SITE ]]; then
    site_exists "$SITE" || die "Unknown site: $SITE"
    return 0
  fi
  while IFS= read -r s; do [[ -n $s ]] && all+=("$s"); done < <(sites_list)
  if ((${#all[@]} == 0)); then
    info "No sites configured. Launching site creation wizard:"
    cmd_add_site
    SITE="$NEW_SITE_DOMAIN"
    return 0
  fi

  interactive || die "Non-interactive deploy requires --site (sites: ${all[*]})"
  # whiptail menus scroll and jump to a typed letter; the plain list can be filtered first
  if [[ $UI == plain ]] && ((${#all[@]} > 10)); then
    printf '\n%d sites available. Filter by domain name (or Enter for all): ' "${#all[@]}" >&2
    read -r filter || die "Input closed"
  fi

  opts=()
  for s in "${all[@]}"; do
    if [[ -z $filter || $s == *"$filter"* ]]; then opts+=("$s" "$s"); fi
  done
  opts+=(__add "+ Add a new site")
  ui_menu SITE "Site to deploy:" '' "${opts[@]}"

  if [[ $SITE == __add ]]; then
    cmd_add_site
    SITE="$NEW_SITE_DOMAIN"
  fi
}

# ---------------------------------------------------------------- site user
check_site_user_name() {
  [[ $1 =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || { echo "Use lower-case letters, digits, - and _ (up to 32 characters)"; return 1; }
  case $1 in root|www-data|nobody|daemon|mysql|redis|nginx) echo "'$1' is a system account"; return 1 ;; esac
}

# pick_site_user: one Linux user for all the server's sites (test server), or one per site (production).
# Saved on the server by the deploy. Sets SITE_USER, the owner of this site's files and of the git key.
# Socket, container, database and Redis names stay per site whichever is chosen.
pick_site_user() {
  local per_site shared='' choice='per_site'
  per_site=$(compute_linux_user "$SITE")
  case ${SITE_USER_NOW:-per_site} in per_site) ;; *) shared=$SITE_USER_NOW choice=shared ;; esac
  if [[ -n $CLI_SITE_USER ]]; then
    case $CLI_SITE_USER in
      per-site|per_site) choice=per_site shared='' ;;
      *) choice=shared shared=$CLI_SITE_USER ;;
    esac
  elif interactive; then
    ui_menu choice "Linux users on $TARGET_LABEL:" "$choice" \
      shared   "1 user for all sites (test server)" \
      per_site "1 user per site (production)"
    if [[ $choice == shared ]]; then ui_input shared "Name of the user for all sites" "${shared:-web}" check_site_user_name; fi
  fi
  if [[ $choice == shared ]]; then
    local why
    why=$(check_site_user_name "$shared") || die "--site-user: $why"
    SITE_USER=$shared
  else
    SITE_USER=$per_site
  fi
  if [[ ${SITE_USER_NOW:-per_site} != "$([[ $choice == shared ]] && echo "$shared" || echo per_site)" ]] && [[ -n $SITE_USER_NOW ]]; then
    info "The server's other sites change to this on their next deploy."
  fi
}

# ---------------------------------------------------------------- branch & repo verification
# target_ls_remote REPO ARG: git ls-remote on the target as the site user, with the key in its ~/.ssh.
# Exit code 90: the site user or its key is missing.
target_ls_remote() {
  local u=$SITE_USER
  target_root "h=\$(getent passwd $(printf '%q' "$u") | cut -d: -f6); [ -n \"\$h\" ] && [ -f \"\$h/.ssh/id_rsa\" ] || exit 90
    cd / && GIT_TERMINAL_PROMPT=0 GIT_SSH_COMMAND='ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o LogLevel=ERROR' \\
      runuser -u $(printf '%q' "$u") -- env HOME=\"\$h\" timeout 15 git ls-remote $(printf '%q %q' "$1" "$2")"
}

verify_repo_branch() {
  local branch="$1" fatal="${2:-1}"
  local repo key_path perms
  repo=$(site_field "$SITE" repo)
  key_path=$(site_field "$SITE" deploy_key)

  # No key waiting here: the key is in the site user's ~/.ssh on the target, so the check runs there
  local on_target=0
  if [[ $repo =~ ^(git@|ssh://) ]]; then
    if [[ -z $key_path ]]; then
      on_target=1
    elif [[ ! -f $key_path ]]; then
      die "Git key not found: $key_path. Run: deploy.sh add-site $SITE"
    else
    perms=$(stat -c %a "$key_path" 2>/dev/null || echo "")
    if [[ $perms != 600 && $perms != 400 ]]; then
      die "Git key $key_path must be chmod 600 or 400 (is $perms)."
    fi
    fi
  fi

  if ((SKIP_REPO_CHECK)); then
    info "Skipping repository remote check (--skip-repo-check given)."
    return 0
  fi

  info "Verifying repository access and branch '$branch' (15s timeout)..."
  local ls_stdout='' ls_err='' rc=0 tmp_err
  tmp_err=$(mktemp)
  if ((on_target)); then
    ls_stdout=$(target_ls_remote "$repo" "$branch" 2>"$tmp_err") || rc=$?
    if ((rc == 90)); then
      rm -f "$tmp_err"
      die "$SITE_USER has no git key on $TARGET_LABEL. Add both keys with: deploy.sh add-site $SITE"
    fi
  elif [[ -n ${key_path:-} ]]; then
    ls_stdout=$(GIT_SSH_COMMAND="ssh -i '$key_path' -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o LogLevel=ERROR" timeout 15 git ls-remote "$repo" "$branch" 2>"$tmp_err") || rc=$?
  else
    ls_stdout=$(GIT_SSH_COMMAND="ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new" timeout 15 git ls-remote "$repo" "$branch" 2>"$tmp_err") || rc=$?
  fi
  ls_err=$(cat "$tmp_err")
  rm -f "$tmp_err"

  if ((rc == 124)); then
    die "Repository check timed out (15s) for '$repo'. Check network access or pass --skip-repo-check."
  elif ((rc != 0)); then
    if [[ $ls_err =~ Permission\ denied|publickey ]]; then
      die "Permission denied (publickey) accessing '$repo'. Ensure the deploy key is registered on the repository."
    else
      die "Could not reach repository '$repo': $ls_err. Check repository URL or pass --skip-repo-check."
    fi
  elif [[ -z $ls_stdout ]]; then
    local heads=''
    if ((on_target)); then
      heads=$(target_ls_remote "$repo" --heads 2>/dev/null | awk '{print $2}' | sed 's#refs/heads/##' | head -n 10 | tr '\n' ' ' || true)
    elif [[ -n ${key_path:-} ]]; then
      heads=$(GIT_SSH_COMMAND="ssh -i '$key_path' -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o LogLevel=ERROR" timeout 15 git ls-remote --heads "$repo" 2>/dev/null | awk '{print $2}' | sed 's#refs/heads/##' | head -n 10 | tr '\n' ' ' || true)
    else
      heads=$(GIT_SSH_COMMAND="ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new" timeout 15 git ls-remote --heads "$repo" 2>/dev/null | awk '{print $2}' | sed 's#refs/heads/##' | head -n 10 | tr '\n' ' ' || true)
    fi
    VERIFY_MSG="Branch '$branch' not found in repository '$repo'.${heads:+ Available branches: $heads}"
    [[ $UI == whiptail && $fatal == 0 ]] || { warn "Branch '$branch' not found in repository '$repo'."; [[ -z $heads ]] || warn "Available branches: $heads"; }
    if ((fatal)); then die "Branch '$branch' not found in repository '$repo'."; fi
    return 1
  fi
  return 0
}

pick_branch() {
  local prev_b
  prev_b=$(site_field "$SITE" branch)
  local def_b="${prev_b:-main}"

  if [[ -n "${CLI_BRANCH:-}" ]]; then
    BRANCH="$CLI_BRANCH"
    verify_repo_branch "$BRANCH" 1
    return 0
  fi

  if ! interactive; then
    if [[ -n "$prev_b" ]]; then
      BRANCH="$prev_b"
    else
      die "Non-interactive deploy requires --branch flag (no previous branch remembered for '$SITE')"
    fi
    verify_repo_branch "$BRANCH" 1
    return 0
  fi

  local cand=''
  while true; do
    ui_input cand "Git branch to deploy${prev_b:+ (last time: $prev_b)}" "$def_b"
    [[ -n $cand ]] || { ui_error "Branch cannot be empty"; continue; }
    if verify_repo_branch "$cand" 0; then
      BRANCH="$cand"
      break
    fi
    [[ $UI != whiptail ]] || ui_error "$VERIFY_MSG"
  done
}

# ---------------------------------------------------------------- traffic selection
pick_traffic() {
  validate_traffic_json || die "traffic.json invalid"
  local available_levels=() l
  while IFS= read -r l; do [[ -n $l ]] && available_levels+=("$l"); done < <(jq -r 'keys[]' "$TRAFFIC_JSON")

  local prev_t
  prev_t=$(site_field "$SITE" traffic)
  local def_t="${prev_t:-low}"
  if [[ ! " ${available_levels[*]} " =~ " ${def_t} " ]]; then
    def_t="${available_levels[0]}"
  fi

  if [[ -n "${CLI_TRAFFIC:-}" ]]; then
    if [[ " ${available_levels[*]} " =~ " ${CLI_TRAFFIC} " ]]; then
      TRAFFIC="$CLI_TRAFFIC"
      return 0
    else
      die "Invalid --traffic '$CLI_TRAFFIC' (valid: ${available_levels[*]})"
    fi
  fi

  if ! interactive; then
    TRAFFIC="$def_t"
    return 0
  fi

  local args=()
  for l in "${available_levels[@]}"; do
    args+=("$l" "$(jq -r --arg l "$l" '.[$l] | "\($l): up to \(.max_children) PHP workers (\(.pm))"' "$TRAFFIC_JSON")")
  done
  ui_menu TRAFFIC "Traffic level of $SITE${prev_t:+ (last time: $prev_t)}:" "$def_t" "${args[@]}"
}

# ---------------------------------------------------------------- PHP version selection
pick_php() {
  local prev_p
  prev_p=$(site_field "$SITE" php_version)
  local def_p="${prev_p:-8.2}"

  # docker_stack has one shared image, enzipe/php-fpm:8.2-alpine
  if [[ $SETUP == docker_stack ]]; then
    if [[ -n ${CLI_PHP:-} && $CLI_PHP != 8.2 ]]; then
      die "docker_stack runs PHP 8.2 only (shared image enzipe/php-fpm:8.2-alpine). Use --php 8.2 or the native_lemp setup."
    fi
    if [[ -n $prev_p && $prev_p != 8.2 ]]; then
      warn "$SITE used PHP $prev_p before; docker_stack runs PHP 8.2 (no mongodb extension in this image)."
    fi
    PHP_VERSION=8.2
    info "PHP version: 8.2 (docker_stack image enzipe/php-fpm:8.2-alpine)"
    return 0
  fi

  if [[ -n "${CLI_PHP:-}" ]]; then
    if [[ " ${PHP_VERSIONS[*]} " =~ " ${CLI_PHP} " ]]; then
      PHP_VERSION="$CLI_PHP"
    else
      die "Invalid --php '$CLI_PHP' (valid: ${PHP_VERSIONS[*]})"
    fi
  elif ! interactive; then
    PHP_VERSION="$def_p"
  else
    local args=() v
    for v in "${PHP_VERSIONS[@]}"; do
      args+=("$v" "PHP $v")
    done
    ui_menu PHP_VERSION "PHP version for $SITE${prev_p:+ (last time: $prev_p)}:" "$def_p" "${args[@]}"
  fi
}

# ---------------------------------------------------------------- docker stack (server settings)
# valid_ip_list "LIST": every word is an IPv4/IPv6 address, optionally with /prefix
valid_ip_list() {
  local w o
  for w in $1; do
    if [[ $w =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})(/([0-9]{1,2}))?$ ]]; then
      for o in "${BASH_REMATCH[@]:1:4}"; do ((10#$o <= 255)) || return 1; done
      [[ -z ${BASH_REMATCH[6]} ]] || ((10#${BASH_REMATCH[6]} <= 32)) || return 1
    elif [[ $w =~ ^[0-9A-Fa-f:]*:[0-9A-Fa-f:]*(/([0-9]{1,3}))?$ ]]; then
      [[ -z ${BASH_REMATCH[2]} ]] || ((10#${BASH_REMATCH[2]} <= 128)) || return 1
    else
      return 1
    fi
  done
  return 0
}

check_ip_list() {
  local l
  l=$(tr ',' ' ' <<< "$1" | xargs)
  [[ -n $l ]] && valid_ip_list "$l" && return 0
  echo "Enter IP addresses separated by spaces (e.g. 1.2.3.4 10.0.0.0/24)"; return 1
}
check_ip_list_or_none() {
  [[ $1 != none ]] || return 0
  check_ip_list "$1" || { echo "Enter IP addresses separated by spaces (e.g. 1.2.3.4 10.0.0.0/24), or 'none'"; return 1; }
}

# ask_ip_list VAR PROMPT DEFAULT [ALLOW_NONE] [HELP]: space-separated IPs; Enter keeps DEFAULT
ask_ip_list() {
  # (not "ans": ui_input has a local of that name, its answer would never reach us)
  local __ipl_var=$1 prompt=$2 def=$3 allow_none=${4:-0} help=${5:-} ipl_ans
  ui_input ipl_ans "$prompt" "${def:-none}" "$( ((allow_none)) && echo check_ip_list_or_none || echo check_ip_list)" "$help"
  ipl_ans=$(tr ',' ' ' <<< "$ipl_ans" | xargs)
  [[ $ipl_ans != none ]] || ipl_ans=''
  printf -v "$__ipl_var" '%s' "$ipl_ans"
}

# Server-level settings of /opt/docker-stack, asked on the first docker_stack deploy to a server
# (or with --stack-config). Later deploys keep what is on the server.
pick_stack_config() {
  [[ $SETUP == docker_stack ]] || return 0
  if ((STACK_CONFIGURED && ! STACK_CONFIG)) && [[ -z $CLI_STACK_ADMIN_IPS$CLI_STACK_WHITELIST_IPS ]]; then
    return 0
  fi
  STACK_CONFIGURE=1
  local cur_admin cur_white cur_wd
  cur_admin=$(echo "$STACK_SETTINGS_JSON" | jq -r 'if has("admin_ips") then (.admin_ips | join(" ")) else "DEFAULT" end')
  cur_white=$(echo "$STACK_SETTINGS_JSON" | jq -r 'if has("whitelist_ips") then (.whitelist_ips | join(" ")) else "DEFAULT" end')
  cur_wd=$(echo "$STACK_SETTINGS_JSON" | jq -r '.watchdog // false')
  [[ $cur_admin != DEFAULT ]] || cur_admin=$STACK_DEFAULT_ADMIN_IPS
  [[ $cur_white != DEFAULT ]] || cur_white=$STACK_DEFAULT_WHITELIST_IPS

  if ! interactive; then
    STACK_ADMIN_IPS=${CLI_STACK_ADMIN_IPS:-$cur_admin}
    STACK_WHITELIST_IPS=${CLI_STACK_WHITELIST_IPS:-$cur_white}
    [[ $STACK_ADMIN_IPS != none ]] || STACK_ADMIN_IPS=''
    [[ -z $STACK_ADMIN_IPS ]] || valid_ip_list "$STACK_ADMIN_IPS" || die "Invalid --stack-admin-ips '$STACK_ADMIN_IPS'"
    valid_ip_list "$STACK_WHITELIST_IPS" || die "Invalid --stack-whitelist-ips '$STACK_WHITELIST_IPS'"
  else
    UI_TITLE="Docker stack settings"
    ask_ip_list STACK_ADMIN_IPS "Allowed IPs (separated by spaces, or 'none' for public sites)" \
      "$( [[ -n $cur_admin ]] && echo "$cur_admin" || echo none)" 1 \
      "Docker stack settings for $TARGET_LABEL$( ((STACK_CONFIGURED)) && echo ', changing the current ones' || echo ', asked once'):"$'\n'"Every site on the server is limited to these IPs (snippets/allowed_admin_ips.conf, staging lock). 'none' makes the sites public. This server itself (127.0.0.1) is always allowed."
    ask_ip_list STACK_WHITELIST_IPS "Rate-limit whitelist IPs" "$cur_white" 0 \
      'IPs that skip the nginx rate limits (geo $whitelist in nginx.conf):'
    UI_TITLE=''
    STACK_ADMIN_IPS=${STACK_ADMIN_IPS:-}
  fi

  # Discord webhook for the container watchdog: hidden input, never written on this machine
  local hook=${DEPLOY_DISCORD_WEBHOOK:-}
  if [[ -z $hook ]] && interactive; then
    local keep_hint='empty = no alerts'
    [[ $cur_wd == true ]] && keep_hint='empty = keep the current webhook'
    while true; do
      ui_secret hook "Discord webhook URL for container alerts ($keep_hint, input hidden)"
      hook=$(ui_trim "$hook")
      [[ -z $hook || $hook =~ ^https://((ptb|canary)\.)?discord(app)?\.com/api/webhooks/[0-9]+/[A-Za-z0-9_-]+$ ]] && break
      ui_error "That is not a Discord webhook URL (https://discord.com/api/webhooks/<id>/<token>)"
    done
  fi
  if [[ -n $hook ]]; then
    [[ $hook =~ ^https://((ptb|canary)\.)?discord(app)?\.com/api/webhooks/[0-9]+/[A-Za-z0-9_-]+$ ]] \
      || die "DEPLOY_DISCORD_WEBHOOK is not a Discord webhook URL"
    export DEPLOY_DISCORD_WEBHOOK="$hook"
    STACK_WEBHOOK_STATE="set (alerts on)"
  elif [[ $cur_wd == true ]]; then
    STACK_WEBHOOK_STATE="unchanged (alerts on)"
  else
    STACK_WEBHOOK_STATE="none (watchdog not installed)"
  fi
}

stack_summary() {
  if [[ $SETUP != docker_stack ]]; then return 0; fi
  if ((STACK_CONFIGURE)); then
    local n
    n=$(wc -w <<< "$STACK_ADMIN_IPS")
    printf '  Stack       : %s (/opt/docker-stack)\n' "$( ((STACK_CONFIGURED)) && echo 'new settings' || echo 'first install')"
    if ((n > 0)); then
      printf '  Site access : only %s IP(s) + this server (staging lock): %s\n' "$n" "$STACK_ADMIN_IPS"
    else
      printf '  Site access : public\n'
    fi
    printf '  Alerts      : %s\n' "$STACK_WEBHOOK_STATE"
  else
    printf '  Stack       : existing /opt/docker-stack (settings kept; --stack-config to change)\n'
  fi
  if ((STACK_LEGACY)); then
    printf '  Old stack   : /opt/php-stack is stopped (containers removed, files kept); its sites need a new deploy\n'
  fi
}

# ---------------------------------------------------------------- environment / db
check_not_empty() { [[ -n $1 ]] || { echo "This cannot be empty"; return 1; }; }
check_port() { [[ $1 =~ ^[0-9]+$ ]] && (($1 >= 1 && $1 <= 65535)) || { echo "Enter a port number (1-65535)"; return 1; }; }
check_abs_path() { [[ $1 == /* ]] || { echo "Enter an absolute path (starting with /)"; return 1; }; }
check_local_file() { [[ -n $1 ]] || { echo "A file is required"; return 1; }; [[ -f $1 ]] || { echo "File '$1' does not exist"; return 1; }; }
# resolve_local_path PATH: an absolute path as it is; ~/x in the home of the user who ran deploy.sh
# (also under sudo); another relative path from the folder deploy.sh was started in, else from $BASE
# (paths saved in sites.json, like data/backups/x.sql, are relative to $BASE).
resolve_local_path() {
  local p=$1 h=$HOME
  [[ -z ${SUDO_USER:-} ]] || h=$(getent passwd "$SUDO_USER" | cut -d: -f6)
  if [[ $p == "~" || $p == "~/"* ]]; then p=$h${p:1}; fi
  if [[ $p != /* ]]; then
    if [[ -e $CALLER_PWD/$p ]]; then p=$CALLER_PWD/$p; else p=$BASE/$p; fi
  fi
  printf '%s' "$p"
}
check_dump_path() {
  local f
  [[ -n $1 ]] || { echo "Path cannot be empty"; return 1; }
  f=$(resolve_local_path "$1")
  [[ -f $f ]] && return 0
  if [[ $f == "$1" ]]; then echo "File '$f' not found"
  else echo "File '$f' not found (you typed: $(printf '%q' "$1"))"; fi
  return 1
}
ensure_production_db() {
  local db_host db_port db_name db_user db_pass1 db_pass2
  db_host=$(site_field "$SITE" db.host)
  db_port=$(site_field "$SITE" db.port)
  db_name=$(site_field "$SITE" db.name)
  db_user=$(site_field "$SITE" db.user)

  # --db-* flags set (or change) the saved settings; they are needed on a first non-interactive deploy
  if [[ -n $CLI_DB_HOST$CLI_DB_PORT$CLI_DB_NAME$CLI_DB_USER ]]; then
    db_host=${CLI_DB_HOST:-$db_host}
    db_port=${CLI_DB_PORT:-${db_port:-3306}}
    db_name=${CLI_DB_NAME:-${db_name:-$(compute_linux_user "$SITE")_prod}}
    db_user=${CLI_DB_USER:-${db_user:-$(compute_linux_user "$SITE")}}
    [[ -n $db_host ]] || die "--db-host is required for the first production deploy of '$SITE'"
    [[ $db_port =~ ^[0-9]+$ ]] || die "Invalid --db-port '$db_port'"
    update_site_db_block "$SITE" "$db_host" "$db_port" "$db_name" "$db_user"
  elif [[ -z $db_host ]] && ! interactive; then
    die "First production deploy of '$SITE' needs its database settings: --db-host HOST [--db-port 3306] [--db-name NAME] [--db-user USER] (saved for later deploys)"
  fi

  if [[ -z $db_host ]]; then
    info "Configuring production database for site '$SITE' (asked once and saved):"
    local def_host def_port def_name def_user
    def_host=$(jq -r '.sites | to_entries | map(select(.value.db.host != null)) | last | .value.db.host // empty' "$SITES_JSON" 2>/dev/null || true)
    def_port=$(jq -r '.sites | to_entries | map(select(.value.db.port != null)) | last | .value.db.port // empty' "$SITES_JSON" 2>/dev/null || true)
    def_port=${def_port:-3306}
    def_name="$(compute_linux_user "$SITE")_prod"
    def_user="$(compute_linux_user "$SITE")"

    UI_TITLE="Production database of $SITE (asked once, saved in sites.json)"
    ui_input db_host "Database host" "$def_host" check_not_empty
    ui_input db_port "Database port" "$def_port" check_port
    ui_input db_name "Database name" "$def_name" check_not_empty
    ui_input db_user "Database user" "$def_user" check_not_empty
    UI_TITLE=''

    update_site_db_block "$SITE" "$db_host" "$db_port" "$db_name" "$db_user"
  fi

  # Production database password is asked at every deploy and never written to disk
  if ((KEEP_DB_PASSWORD)); then
    info "Keeping the database password that is already in the site's .env (site moved between setups)."
  elif [[ -n "${DEPLOY_DB_PASSWORD:-}" ]]; then
    info "Using database password from DEPLOY_DB_PASSWORD environment variable."
  elif ! interactive; then
    die "Non-interactive production deploy requires DEPLOY_DB_PASSWORD environment variable."
  else
    while true; do
      ui_secret db_pass1 "Database password for $SITE (asked at every deploy, never saved)"
      [[ -n $db_pass1 ]] || { ui_error "Password cannot be empty"; continue; }
      ui_secret db_pass2 "Confirm the database password"
      if [[ "$db_pass1" == "$db_pass2" ]]; then break; fi
      ui_error "Passwords did not match. Please try again."
    done
    export DEPLOY_DB_PASSWORD="$db_pass1"
  fi
}

# The SQL dump for --db-mode import_backup: --db-backup PATH, else asked (the last one is the default).
# It is copied to data/backups/ and remembered per site.
ensure_backup_path() {
  local bpath='' saved full_path rel_dst
  saved=$(site_field "$SITE" db.backup_path)
  [[ -n $saved && -f $BASE/$saved ]] || saved=''

  if [[ -n $CLI_DB_BACKUP ]]; then
    bpath=$CLI_DB_BACKUP
  elif ! interactive; then
    [[ -n $saved ]] || die "--db-mode import_backup needs a dump file: --db-backup PATH (.sql or .sql.gz)"
    info "Using database backup: $saved"
    return 0
  else
    ui_input bpath "Path to the database dump file on this machine (.sql or .sql.gz)" "$saved" check_dump_path
  fi

  full_path=$(resolve_local_path "$bpath")
  [[ -f $full_path ]] || die "Database dump '$full_path' not found$([[ $full_path == "$bpath" ]] || printf ' (given: %q)' "$bpath")"
  [[ $full_path =~ \.sql(\.gz)?$ ]] || die "Database dump must be a .sql or .sql.gz file: $full_path"
  mkdir -p "$DATA/backups"
  rel_dst="data/backups/$(basename "$full_path")"
  if [[ $(readlink -f "$full_path") != $(readlink -f "$BASE/$rel_dst") ]]; then
    cp -f "$full_path" "$BASE/$rel_dst"
    info "Backup copied to $rel_dst"
  fi
  if ((! DRY_RUN)); then update_site_field "$SITE" "db.backup_path" "$rel_dst"; fi
  info "Using database backup: $rel_dst"
}

pick_environment() {
  if [[ -n $ENVIRONMENT ]]; then
    if [[ ! $ENVIRONMENT =~ ^(production|local)$ ]]; then
      die "Invalid value '$ENVIRONMENT' for ENVIRONMENT (valid: production, local)"
    fi
  elif ! interactive; then
    die "Non-interactive deploy requires setting --env production|local"
  else
    local prev_env   # production sites have saved database settings; a deployed site without them is local
    prev_env=$(jq -r --arg s "$SITE" '.sites[$s] | if .db.host then "production" elif .branch then "local" else empty end' "$SITES_JSON")
    ui_menu ENVIRONMENT "Environment of $SITE:" "$prev_env" \
      production "production: the real database on another server (nothing is seeded or imported)" \
      local      "local: a test copy with its own database on the target"
  fi

  if [[ $ENVIRONMENT == production ]]; then
    DB_MODE="remote"
    ensure_production_db
  else
    [[ $DB_MODE != remote ]] || die "Refusing: a local deploy must never use the production database"
    if [[ -n $MOVE_DUMP ]]; then
      DB_MODE=import_backup
      info "Local database: imported from $MOVE_DUMP (taken on the server before the switch)"
      return 0
    fi
    if [[ -n $DB_MODE ]]; then
      [[ $DB_MODE =~ ^(seed|import_backup|none)$ ]] || die "Invalid --db-mode '$DB_MODE' for a local deploy (valid: seed, import_backup, none)"
    else
      interactive || die "Non-interactive deploy requires setting --db-mode (options: seed import_backup none)"
      ui_menu DB_MODE "Local database of $SITE:" none \
        seed          "seed: run the seeders (and the migrations when the database is empty)" \
        import_backup "import_backup: import a .sql or .sql.gz dump from this machine" \
        none          "none: keep the database as it is"
    fi
    if [[ $DB_MODE == import_backup ]]; then
      ensure_backup_path
    fi
  fi
}

# ---------------------------------------------------------------- TLS / SSL selection
# cert_pair_error CERT KEY: prints why the pair cannot be used and returns 1; returns 0 when it is fine.
cert_pair_error() {
  local cf="$1" kf="$2" c_pub k_pub
  [[ -f $cf ]] || { echo "Certificate file '$cf' not found"; return 1; }
  [[ -f $kf ]] || { echo "Private key file '$kf' not found"; return 1; }
  [[ -r $cf ]] || { echo "Certificate file '$cf' is not readable"; return 1; }
  [[ -r $kf ]] || { echo "Private key file '$kf' is not readable"; return 1; }

  if ! openssl x509 -in "$cf" -noout >/dev/null 2>&1; then
    echo "The certificate is not a valid PEM certificate"; return 1
  fi
  if ! openssl x509 -in "$cf" -noout -checkend 0 >/dev/null 2>&1; then
    echo "The certificate is expired"; return 1
  fi
  if ! openssl pkey -passin pass: -in "$kf" -noout >/dev/null 2>&1; then
    echo "The private key is not a valid unencrypted PEM key"; return 1
  fi

  c_pub=$(openssl x509 -in "$cf" -noout -pubkey 2>/dev/null | openssl pkey -pubin -outform DER 2>/dev/null | sha256sum | awk '{print $1}')
  k_pub=$(openssl pkey -passin pass: -in "$kf" -pubout -outform DER 2>/dev/null | sha256sum | awk '{print $1}')
  if [[ "$c_pub" != "$k_pub" ]]; then
    echo "The certificate does not match the private key"; return 1
  fi
  return 0
}

verify_cert_pair() {
  local err
  err=$(cert_pair_error "$1" "$2") || die "$err ($1, $2)"
}

# Warns when the certificate does not name the site or one of its aliases (a common paste mistake).
warn_cert_host() {
  local cf="$1" h
  for h in "$SITE" $(jq -r --arg s "$SITE" '.sites[$s].aliases // [] | .[]' "$SITES_JSON"); do
    if ! openssl x509 -in "$cf" -noout -checkhost "$h" 2>/dev/null | grep -q 'does match'; then
      warn "The certificate does not cover '$h'."
    fi
  done
}

# pem_line SECRET [TIMEOUT]: reads one pasted line into PEM_LINE (not echoed when SECRET=1).
# Returns non-zero at end of input, or when TIMEOUT seconds pass without a line.
pem_line() {
  local secret=$1 timeout=${2:-} line='' part rc first=1 args=(-r)
  if [[ -n $PEM_PENDING ]]; then PEM_LINE=$PEM_PENDING; PEM_PENDING=''; return 0; fi
  if ((secret)); then args+=(-s); fi
  # Read one character at a time (read -N switches the terminal to character mode; mixing it with
  # line reads loses pasted text). A paste often ends without a newline after the -----END ...-----
  # line, so that line counts as complete once nothing more arrives for a moment: no Enter is needed
  # after pasting. With TIMEOUT: no text within TIMEOUT seconds means the paste is over (return 1).
  while true; do
    part=''; rc=0
    if ((first)) && [[ -n $timeout ]]; then IFS= read "${args[@]}" -N 1 -t "$timeout" part || rc=$?
    else IFS= read "${args[@]}" -N 1 -t 0.7 part || rc=$?; fi
    if ((rc == 0)); then
      first=0
      [[ $part == $'\n' || $part == $'\r' ]] && break
      line+=$part
      continue
    fi
    if ((rc > 128)); then
      if ((first)) && [[ -n $timeout ]]; then return 1; fi
      [[ $(pem_clean "$line") == -----END*----- ]] && break
      continue
    fi
    [[ -n $line ]] && break   # end of input
    return 1
  done
  PEM_LINE=$(pem_clean "$line")
}

# pem_clean TEXT: without the bracketed-paste markers some terminals put around pasted text, and
# without a trailing carriage return (text copied from Windows)
pem_clean() { local l=${1//$'\e[200~'/}; l=${l//$'\e[201~'/}; printf '%s' "${l%$'\r'}"; }

# swallow_keys: drops keys pressed right after a paste (an Enter pressed out of habit), so they do not
# answer the next question. Waits until no key arrives for a second (at most about 5 seconds).
swallow_keys() {
  local _k i
  for i in 1 2 3 4 5; do IFS= read -rs -t 1 -n 10000 _k || break; done
  return 0
}

# read_pem KIND OUTFILE SECRET: reads one pasted PEM text (KIND = CERTIFICATE or KEY) into OUTFILE.
# Reading stops at the END line. For a certificate, more certificates pasted in the same go
# (a full chain) are picked up too; a private key pasted together with it is kept for the next call.
read_pem() {
  local kind=$1 out=$2 secret=$3 begin_re more
  if [[ $kind == CERTIFICATE ]]; then
    begin_re='^-----BEGIN CERTIFICATE-----'
  else
    begin_re='^-----BEGIN ([A-Z]+ )?PRIVATE KEY-----'
  fi
  : > "$out"

  while true; do
    pem_line "$secret" || die "Input closed"
    [[ -z ${PEM_LINE//[[:space:]]/} ]] && continue
    [[ $PEM_LINE =~ $begin_re ]] && break
    if [[ $PEM_LINE =~ ^(ssh-|ecdsa-|sk-) ]]; then
      warn "That is a public key. Paste the private key (it starts with -----BEGIN ... PRIVATE KEY-----)."
    else
      warn "Skipped a line that is not the start of the ${kind,,} (-----BEGIN ...-----)"
    fi
  done

  while true; do
    printf '%s\n' "$PEM_LINE" >> "$out"
    if [[ $PEM_LINE == -----END* ]]; then
      [[ $kind == CERTIFICATE ]] || return 0
      # A full chain arrives in one paste: wait briefly for another certificate block.
      more=0
      while pem_line "$secret" 1; do
        [[ -z ${PEM_LINE//[[:space:]]/} ]] && continue
        if [[ $PEM_LINE =~ $begin_re ]]; then more=1; else PEM_PENDING=$PEM_LINE; fi
        break
      done
      ((more)) || return 0
    else
      pem_line "$secret" || die "Input closed"
      while [[ -z ${PEM_LINE//[[:space:]]/} ]]; do pem_line "$secret" || die "Input closed"; done
    fi
  done
}

# Option 1: certificate files that already exist on the target machine.
pick_tls_existing() {
  local prev_cp prev_kp def_c def_k
  prev_cp=$(site_field "$SITE" tls.cert_path)
  prev_kp=$(site_field "$SITE" tls.key_path)
  [[ $prev_cp != "$TLS_LEGACY_DIR/$SITE/fullchain.pem" ]] || prev_cp=''
  [[ $prev_kp != "$TLS_LEGACY_DIR/$SITE/privkey.pem" ]] || prev_kp=''
  def_c="${prev_cp:-$TLS_TARGET_DIR/$SITE/certificate.crt}"
  def_k="${prev_kp:-$TLS_TARGET_DIR/$SITE/privatekey.key}"

  if [[ -n $CLI_CERT_PATH || -n $CLI_KEY_PATH ]]; then
    TLS_CERT_PATH="${CLI_CERT_PATH:-$def_c}"
    TLS_KEY_PATH="${CLI_KEY_PATH:-$def_k}"
  elif ! interactive; then
    TLS_CERT_PATH="$def_c"
    TLS_KEY_PATH="$def_k"
  else
    UI_TITLE="Certificate files on $TARGET_LABEL"
    ui_input TLS_CERT_PATH "Certificate file on the target" "$def_c" check_abs_path
    ui_input TLS_KEY_PATH "Private key file on the target" "$def_k" check_abs_path
    UI_TITLE=''
  fi

  [[ $TLS_CERT_PATH == /* && $TLS_KEY_PATH == /* ]] \
    || die "Certificate and key paths must be absolute paths on the target"
  info "The certificate is checked on the target and copied to $TLS_TARGET_DIR/$SITE/, where nginx reads it."
  if [[ $TLS_CERT_PATH == /etc/letsencrypt/* ]]; then
    info "Renewals at $TLS_CERT_PATH are only picked up on the next deploy. Option 3 (certbot) renews automatically."
  fi
}

# Option 2: certificate and key pasted in the terminal (e.g. a Cloudflare Origin Certificate).
pick_tls_paste() {
  if ! interactive; then
    die "--tls paste needs a terminal to paste into. Non-interactive: use --tls existing --cert-path PATH --key-path PATH (files on the target) or --tls files --cert-file PATH --cert-key PATH (files on this machine)."
  fi
  ui_screen_off   # the certificate and key are pasted into the terminal
  CERT_FILE="$TMP_DIR/pasted-fullchain.pem"
  KEY_FILE="$TMP_DIR/pasted-privkey.pem"
  printf '\nCloudflare: SSL/TLS > Origin Server > Create Certificate (key format PEM),\n' >&2
  printf 'then set SSL/TLS encryption mode to "Full (strict)".\n' >&2

  local err
  while true; do
    # Input is hidden for both, so a key pasted together with the certificate never shows on screen.
    printf '\nPaste the certificate (-----BEGIN CERTIFICATE----- ... -----END CERTIFICATE-----).\n' >&2
    printf 'Pasted text is not shown. No need to press Enter: it is read as soon as the END line arrives.\n' >&2
    read_pem CERTIFICATE "$CERT_FILE" 1
    printf '\n' >&2
    info "Certificate received ($(grep -c 'BEGIN CERTIFICATE' "$CERT_FILE") certificate block(s))."
    if [[ -z $PEM_PENDING ]]; then
      printf '\nPaste the private key (-----BEGIN PRIVATE KEY----- ... -----END PRIVATE KEY-----):\n' >&2
    fi
    read_pem KEY "$KEY_FILE" 1
    swallow_keys
    printf '\n' >&2
    info "Private key received."
    if err=$(cert_pair_error "$CERT_FILE" "$KEY_FILE"); then break; fi
    warn "$err. Paste both again."
    PEM_PENDING=''
  done
  warn_cert_host "$CERT_FILE"
  info "It will be written to $TLS_TARGET_DIR/$SITE/certificate.crt and privatekey.key on the target."
}

check_email() {
  [[ -z $1 || $1 =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]] || { echo "'$1' is not a valid email address"; return 1; }
}

# Option 3: free Let's Encrypt certificate. certbot runs as "certonly --webroot" on the target, so it
# only writes certificate files and never edits the nginx config.
pick_tls_certbot() {
  local prev_e
  prev_e=$(site_field "$SITE" tls.email)
  if [[ -n $CLI_CERTBOT_EMAIL ]]; then
    CERTBOT_EMAIL="$CLI_CERTBOT_EMAIL"
  elif ! interactive; then
    CERTBOT_EMAIL="$prev_e"
  else
    ui_input CERTBOT_EMAIL "Email for Let's Encrypt expiry notices (empty = none)" "$prev_e" check_email
  fi
  [[ -z $CERTBOT_EMAIL || $CERTBOT_EMAIL =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]] \
    || die "Invalid certbot email '$CERTBOT_EMAIL'"

  info "certbot runs as 'certonly --webroot': it only writes certificate files and never edits the nginx config."
  warn "DNS for $SITE (and its aliases) must point to the target, and port 80 must be reachable from the internet."
}

# Certificate files on THIS machine (--tls files), copied to the target.
pick_tls_files() {
  local prev_c prev_k
  prev_c=$(site_field "$SITE" tls.cert_file)
  prev_k=$(site_field "$SITE" tls.key_file)

  if [[ -n "${CLI_CERT_FILE:-}" && -n "${CLI_CERT_KEY:-}" ]]; then
    CERT_FILE="$CLI_CERT_FILE"
    KEY_FILE="$CLI_CERT_KEY"
  elif ! interactive; then
    if [[ -n $prev_c && -n $prev_k ]]; then
      CERT_FILE="$prev_c"
      KEY_FILE="$prev_k"
    else
      die "Non-interactive deploy with --tls files requires --cert-file and --cert-key"
    fi
  else
    ui_input CERT_FILE "Path to the certificate file on this machine" "$( [[ -f $prev_c ]] && echo "$prev_c")" check_local_file
    ui_input KEY_FILE "Path to the private key file on this machine" "$( [[ -f $prev_k ]] && echo "$prev_k")" check_local_file
    CERT_FILE=$(readlink -f "$CERT_FILE"); KEY_FILE=$(readlink -f "$KEY_FILE")
  fi
  verify_cert_pair "$CERT_FILE" "$KEY_FILE"
}

pick_tls() {
  local prev_m def_m ans
  prev_m=$(site_field "$SITE" tls.mode)
  if [[ $prev_m == keep ]]; then prev_m=existing; fi
  def_m="${prev_m:-none}"

  # Path or email flags imply their mode when --tls is not given.
  if [[ -z $CLI_TLS ]]; then
    if [[ -n $CLI_CERT_FILE || -n $CLI_CERT_KEY ]]; then CLI_TLS=files
    elif [[ -n $CLI_CERT_PATH || -n $CLI_KEY_PATH ]]; then CLI_TLS=existing
    elif [[ -n $CLI_CERTBOT_EMAIL ]]; then CLI_TLS=certbot
    fi
  fi

  if [[ -n "${CLI_TLS:-}" ]]; then
    if [[ " ${TLS_MODES[*]} " =~ " ${CLI_TLS} " ]]; then
      TLS_MODE="$CLI_TLS"
    else
      die "Invalid --tls '$CLI_TLS' (valid: ${TLS_MODES[*]})"
    fi
  elif ! interactive; then
    TLS_MODE="$def_m"
  elif ! ui_yesno "Use SSL (HTTPS) for $SITE?" "$( [[ $def_m != none ]] && echo yes || echo no)"; then
    TLS_MODE=none
  else
    ui_menu TLS_MODE "SSL certificate for $SITE:" "$( [[ $def_m == certbot ]] && echo certbot || echo existing)" \
      existing "Existing certificate files on the target machine (enter their paths)" \
      paste    "Paste the certificate and key here (e.g. a Cloudflare Origin Certificate)" \
      certbot  "Free Let's Encrypt certificate (certbot)"
  fi

  # keep = the certificate already installed in /etc/nginx/cert/<site>/ on the target
  if [[ $TLS_MODE == keep ]]; then
    TLS_MODE=existing
    CLI_CERT_PATH=${CLI_CERT_PATH:-$TLS_TARGET_DIR/$SITE/certificate.crt}
    CLI_KEY_PATH=${CLI_KEY_PATH:-$TLS_TARGET_DIR/$SITE/privatekey.key}
  fi

  case "$TLS_MODE" in
    existing) pick_tls_existing ;;
    paste)    pick_tls_paste ;;
    certbot)  pick_tls_certbot ;;
    files)    pick_tls_files ;;
  esac
}

tls_summary() {
  case "$TLS_MODE" in
    existing) printf 'existing certificate on target (%s)' "$TLS_CERT_PATH" ;;
    paste)    printf 'pasted certificate -> %s/%s/' "$TLS_TARGET_DIR" "$SITE" ;;
    certbot)  printf "Let's Encrypt via certbot (certonly --webroot%s)" "${CERTBOT_EMAIL:+, $CERTBOT_EMAIL}" ;;
    files)    printf 'certificate files from this machine (%s)' "$CERT_FILE" ;;
    *)        printf 'none (plain HTTP)' ;;
  esac
}

cmd_certs() {
  ui_screen_off
  need_cmds openssl jq
  local sites=() d cfile end epoch days flag now; now=$(date +%s)
  while IFS= read -r d; do [[ -n $d ]] && sites+=("$d"); done < <(sites_list)
  printf '%-32s %-12s %s\n' SITE EXPIRES DAYS_LEFT
  local found=0
  for d in "${sites[@]}"; do
    local mode
    mode=$(site_field "$d" tls.mode)
    if [[ "$mode" == "files" ]]; then
      cfile=$(site_field "$d" tls.cert_file)
      if [[ -n $cfile && -f $cfile ]]; then
        end=$(openssl x509 -in "$cfile" -noout -enddate 2>/dev/null | cut -d= -f2 || echo "")
        if [[ -n $end ]]; then
          epoch=$(date -d "$end" +%s 2>/dev/null || echo 0)
          days=$(((epoch - now) / 86400))
          flag=''; if ((days < 30)); then flag='  <-- renew soon'; fi
          printf '%-32s %-12s %s%s\n' "$d" "$(date -d "$end" +%F 2>/dev/null || echo "$end")" "$days" "$flag"
          found=1
        fi
      fi
    fi
  done
  if ((! found)); then
    printf '  (no local certificate files configured in sites.json)\n'
  fi
}

# ---------------------------------------------------------------- summary / confirm / git key
show_summary() {
  local dry=no; if ((DRY_RUN)); then dry=yes; fi
  SUMMARY_TEXT=$({
    printf 'Deploy summary\n\n'
    printf '  Target      : %s\n' "$TARGET_LABEL"
    printf '  Setup       : %s\n' "$SETUP"
    printf '  Linux user  : %s\n' "$SITE_USER"
    if [[ -n $SWITCH_SUMMARY ]]; then
      # built here, once the site is known: the deployed site itself moves too
      local d moving=() closing=()
      for d in "${OLD_SITES[@]}"; do
        if [[ $d == "$SITE" || " ${MOVE_SITES[*]} " == *" $d "* ]]; then moving+=("$d"); else closing+=("$d"); fi
      done
      printf '  Switch      : leave %s (all its sites go offline first)\n' "$TARGET_MARKER"
      ((${#moving[@]} == 0)) || printf '                move to %s: %s\n' "$SETUP" "${moving[*]}"
      ((${#closing[@]} == 0)) || printf '                close (stay offline): %s\n' "${closing[*]}"
    fi
    printf '  Site        : %s\n' "$SITE"
    printf '  Branch      : %s\n' "$BRANCH"
    printf '  Traffic     : %s\n' "$TRAFFIC"
    printf '  PHP version : %s\n' "$PHP_VERSION"
    printf '  Environment : %s\n' "$ENVIRONMENT"
    printf '  Database    : %s\n' "$DB_MODE${MOVE_DUMP:+ (copy from $TARGET_MARKER: $MOVE_DUMP)}"
    printf '  TLS         : %s\n' "$(tls_summary)"
    local sch
    sch=$(jq -r --arg s "$SITE" '.sites[$s].scheduler // empty' "$SITES_JSON")
    if [[ -z $sch ]]; then [[ $ENVIRONMENT == production ]] && sch=true || sch=false; fi
    printf '  Scheduler   : %s\n' "$( [[ $sch == true ]] && echo 'on (cron runs artisan schedule:run every minute)' || echo 'off ("scheduler": true in sites.json to enable)')"
    stack_summary
    redis_summary
    printf '  Dry run     : %s\n' "$dry"
  })
  printf '\n%s\n\n' "$SUMMARY_TEXT" >&2
}

confirm_run() {
  local typed
  if ((ASSUME_YES || DRY_RUN)); then return 0; fi
  [[ -t 0 ]] || die "Not interactive: pass --yes to confirm"
  if [[ $UI == whiptail ]]; then
    UI_TITLE=${CONFIRM_TITLE:-Ready to deploy}
    if [[ $ENVIRONMENT == production ]]; then
      ui_input typed "$SUMMARY_TEXT"$'\n\n'"PRODUCTION deploy. Type the site name ($SITE) to continue:"
      [[ $typed == "$SITE" ]] || die "Aborted"
    else
      ui_yesno "$SUMMARY_TEXT"$'\n\n'"${CONFIRM_QUESTION:-Start the deploy?}" no || die "Aborted"
    fi
    UI_TITLE=''
  elif [[ $ENVIRONMENT == production ]]; then
    read -rp "PRODUCTION deploy. Type the site name ($SITE) to continue: " typed || die "Input closed"
    [[ $typed == "$SITE" ]] || die "Aborted"
  else
    read -rp "Continue? [y/N]: " typed || die "Input closed"
    [[ $typed =~ ^[Yy]$ ]] || die "Aborted"
  fi
}

load_git_key() {
  local key perms
  key=$(site_field "$SITE" deploy_key)
  [[ -n $key ]] || return 0
  [[ -f $key ]] || die "Deploy key not found for $SITE: $key"
  perms=$(stat -c %a "$key" 2>/dev/null || echo "")
  [[ $perms == 600 || $perms == 400 ]] || die "Git key $key must be chmod 600 or 400 (is $perms)"
  ssh-keygen -y -P "" -f "$key" >/dev/null 2>&1 \
    || die "Git key '$key' has a passphrase or is invalid. The site user needs a key without a passphrase."
  [[ -f $key.pub ]] || { ssh-keygen -y -P "" -f "$key" > "$TMP_DIR/git-key.pub"; }
}

# finish_git_key: after a successful deploy the key is in the site user's ~/.ssh: the copy on this
# machine goes (a key file kept elsewhere by hand stays, it is only no longer used).
finish_git_key() {
  local key
  key=$(site_field "$SITE" deploy_key)
  [[ -n $key ]] || return 0
  if [[ $key == "$HOME/.ssh/${SITE}_deploy" ]]; then rm -f "$key" "$key.pub"; else info "Your key file $key is no longer used and can be removed."; fi
  jq --arg d "$SITE" 'del(.sites[$d].deploy_key)' "$SITES_JSON" > "$SITES_JSON.tmp" && mv -f "$SITES_JSON.tmp" "$SITES_JSON"
  info "The git key is now only in the site user's ~/.ssh on $TARGET_LABEL."
}

# ---------------------------------------------------------------- engine (engine/run.sh on the target)
# build_vars: writes $TMP_DIR/bundle/vars.sh, plain bash assignments that engine/run.sh sources on the
# target. Files the target needs from this machine (a certificate, a database dump) go into the bundle
# for a remote target; a local deploy reads them where they are.
build_vars() {
  local u site_json traffic_block play_tls=$TLS_MODE remote=0 bundle=$TMP_DIR/bundle backup='' a
  [[ $TARGET_CONN == local ]] || remote=1
  # A pasted certificate is sent like certificate files from this machine
  [[ $TLS_MODE != paste ]] || play_tls=files
  u=$(compute_linux_user "$SITE")
  site_json=$(jq -c --arg s "$SITE" '.sites[$s]' "$SITES_JSON")
  traffic_block=$(jq -c --arg l "$TRAFFIC" '.[$l]' "$TRAFFIC_JSON")
  rm -rf "$bundle"; mkdir -p "$bundle/files"
  VARS_FILE=$bundle/vars.sh

  sj() { jq -r "if $1 == null then \"\" else ($1 | tostring) end" <<< "$site_json"; }
  tj() { jq -r "if $1 == null then \"\" else ($1 | tostring) end" <<< "$traffic_block"; }
  q() { printf '%s=%q\n' "$1" "$2"; }
  qa() { local n=$1; shift; printf '%s=(' "$n"; (($# == 0)) || printf '%q ' "$@"; printf ')\n'; }
  qj() { local n=$1 json=$2 filter=$3 arr=(); mapfile -t arr < <(jq -r "$filter" <<< "$json"); qa "$n" "${arr[@]}"; }
  # qf NAME LOCAL_PATH: a file the engine reads; copied into the bundle for a remote target. The copy
  # keeps the file's name, so the engine still sees the extension (.sql.gz dumps are read with zcat).
  qf() {
    local f
    if [[ -z $2 ]]; then q "$1" ''
    elif ((remote)); then
      f="$1-$(basename "$2")"; f=${f//[^A-Za-z0-9._-]/_}
      cp -L "$2" "$bundle/files/$f"; printf '%s="$BUNDLE_DIR/files/%s"\n' "$1" "$f"
    else q "$1" "$(readlink -f "$2")"; fi
  }

  if [[ $DB_MODE == import_backup && -z $MOVE_DUMP ]]; then
    backup=$(site_field "$SITE" db.backup_path)
    [[ -n $backup || -z $CLI_DB_BACKUP ]] || backup=data/backups/$(basename "$CLI_DB_BACKUP")
    [[ -z $backup || $backup == /* ]] || backup=$BASE/$backup
  fi

  {
    echo "# vars for one deploy of $SITE, written by deploy.sh $(date '+%F %T'). Removed after the run."
    echo "# Sourced by engine/run.sh on the target."
    q site_domain "$SITE"
    qj site_aliases "$site_json" '.aliases // [] | .[]'
    q site_repo "$(sj .repo)"
    q site_branch "$BRANCH"
    local git_key git_pub=''
    git_key=$(sj .deploy_key)
    if [[ -n $git_key ]]; then git_pub=$git_key.pub; [[ -f $git_pub ]] || git_pub=$TMP_DIR/git-key.pub; fi
    qf site_key_file "$git_key"; qf site_pub_file "$git_pub"
    q site_run_migrations "$(sj .run_migrations)"
    q site_scheduler "$(sj .scheduler)"
    qj site_env_extra_keys "$site_json" '.env_extra // {} | to_entries[] | .key'
    qj site_env_extra_vals "$site_json" '.env_extra // {} | to_entries[] | .value | tostring'
    q site_db_host "$(sj .db.host)"
    q site_db_port "$(sj .db.port)"
    q site_db_name "$(sj .db.name)"
    q site_db_user "$(sj .db.user)"
    q site_db_connection "$(sj .db.connection)"
    qf site_db_backup_file "$backup"
    q redis_password_new "$REDIS_PASSWORD_NEW"
    q setup_type "$SETUP"
    q deploy_env "$ENVIRONMENT"
    q db_mode "$DB_MODE"
    q tls_mode "$play_tls"
    if [[ $play_tls == files ]]; then qf cert_file "$CERT_FILE"; qf key_file "$KEY_FILE"
    else q cert_file ''; q key_file ''; fi
    q tls_cert_path "${TLS_CERT_PATH:-}"
    q tls_key_path "${TLS_KEY_PATH:-}"
    q certbot_email "${CERTBOT_EMAIL:-}"
    q linux_user "$SITE_USER"
    q site_id "$u"
    q site_user_mode "$([[ $SITE_USER == "$u" ]] && echo per_site || echo shared)"
    q local_db_name "$u"
    q local_db_user "$u"
    q redis_prefix "${u}_"
    q web_root public
    q traffic_level "$TRAFFIC"
    for a in pm max_children idle_timeout start_servers min_spare max_spare max_requests mem_limit cpus; do
      q "traffic_$a" "$(tj ".$a")"
    done
    qj traffic_extra_nginx "$traffic_block" '.extra_nginx // [] | .[]'
    q php_version "$PHP_VERSION"
    q switch_mode "${SWITCH_ACTION:-none}"
    q switch_from "${TARGET_MARKER:-}"
    q switch_to "$SETUP"
    qj switch_site_domains "${SWITCH_SITES_JSON:-[]}" '.[].domain'
    qj switch_site_users "${SWITCH_SITES_JSON:-[]}" '.[] | (.site_id // .linux_user)'
    qj switch_site_envs "${SWITCH_SITES_JSON:-[]}" '.[] | .environment // "local"'
    qa dump_sites "${DUMP_SITES[@]}"
    q move_dump "$MOVE_DUMP"
    q keep_db_password "$( ((KEEP_DB_PASSWORD)) && echo true || echo false)"
    q stack_configure "$( ((STACK_CONFIGURE)) && echo true || echo false)"
    q server_refresh "$( ((SERVER_REFRESH)) && echo true || echo false)"
    # shellcheck disable=SC2086
    qa stack_admin_ips $STACK_ADMIN_IPS
    # shellcheck disable=SC2086
    qa stack_whitelist_ips $STACK_WHITELIST_IPS
    # secrets: the production database password and the Discord webhook (this file is mode 0600)
    q db_password "$( [[ $ENVIRONMENT == production ]] && printf '%s' "${DEPLOY_DB_PASSWORD:-}")"
    q discord_webhook "${DEPLOY_DISCORD_WEBHOOK:-}"
    q DRY_RUN "$DRY_RUN"
    q VERBOSE "$VERBOSE"
    q SHOW_TIMINGS "$SHOW_TIMINGS"
    q ENGINE_COLOR "$( [[ -t 1 ]] && echo 1 || echo 0)"
  } > "$VARS_FILE"
  chmod 0600 "$VARS_FILE"
}

# run_engine: engine/run.sh as root on the target. Local: through sudo (asks for the password when
# needed). Remote: the engine and vars.sh are sent with tar over ssh into a private temp folder, run with
# sudo, and removed again.
run_engine() {
  local rc=0
  if [[ -n ${ENGINE_TIMINGS_FILE:-} ]]; then echo "ENGINE_TIMINGS=$(printf '%q' "$ENGINE_TIMINGS_FILE")" >> "$VARS_FILE"; fi
  if [[ $TARGET_CONN == local ]]; then
    local run=(bash "$BASE/engine/run.sh" "$VARS_FILE")
    [[ $(id -u) -eq 0 ]] || run=(sudo "${run[@]}")
    set +e; without_lock "${run[@]}" 2>&1 | tee -a "$LOG_FILE"; rc=${PIPESTATUS[0]}; set -e
    return "$rc"
  fi
  local ssh_opts=(-p "$TARGET_PORT" -o BatchMode=yes -o ControlMaster=auto -o "ControlPath=$TMP_DIR/ssh-%C" -o ControlPersist=60
                  -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10)
  local dest="$TARGET_USER@$TARGET_HOST" rdir sudo='sudo -n'
  ((ASK_BECOME)) && sudo='sudo'
  [[ $TARGET_USER != root ]] || sudo=''
  # the bundle: engine/ next to vars.sh and the files that go along
  cp -a "$BASE/engine" "$TMP_DIR/bundle/engine"
  rdir=$(tar -C "$TMP_DIR/bundle" -czf - . | without_lock ssh "${ssh_opts[@]}" "$dest" \
         'd=$(mktemp -d /tmp/deployer-run.XXXXXX) && tar -xzf - -C "$d" && echo "$d"') \
    || die "Could not send the deploy files to $TARGET_LABEL"
  [[ $rdir == /tmp/deployer-run.* ]] || die "Unexpected answer from $TARGET_LABEL: $rdir"
  local tty=(); ((ASK_BECOME)) && tty=(-t)
  set +e
  without_lock ssh "${ssh_opts[@]}" "${tty[@]}" "$dest" \
    "$sudo bash $rdir/engine/run.sh $rdir/vars.sh; rc=\$?; rm -rf $rdir; exit \$rc" 2>&1 | tee -a "$LOG_FILE"
  rc=${PIPESTATUS[0]}
  ssh "${ssh_opts[@]}" -O exit "$dest" >/dev/null 2>&1
  set -e
  return "$rc"
}

# ---------------------------------------------------------------- commands
usage() {
  cat <<'USAGE'
Usage: deploy.sh [command] [options]

Without a command or option, a menu asks what to do.

Commands:
  deploy                  (default with options) interactive deploy
  server (or stack)       set up or change what a server runs, with or without sites: nginx, PHP
                          versions, MariaDB or MySQL, Redis, certbot, ClickHouse, Node.js (or the docker
                          stack). Unticking a running part stops it (packages and data stay); MariaDB <->
                          MySQL is a swap; a server without sites can change setup. A snapshot is taken
                          first. With -y: --target, --setup, --install and/or --remove (--php, --db-swap)
  rollback                return a server to a snapshot taken before a change (--snapshot ID with -y)
  firewall (or csf)       install and configure the CSF firewall (ports open to everyone, SSH, IPs
                          always allowed / never blocked by LFD / always blocked, ports for some IPs,
                          LFD login blocking), or turn it off, on, or uninstall it. A change runs in
                          TESTING mode first and goes live once a new SSH connection works.
  add-site [DOMAIN]       add a new site or edit existing site
  validate                validate sites.json and traffic.json against schema
  list-sites              list all configured sites
  list-setups             available setup types
  status                  what a target server runs: setup, services, containers, nginx check,
                          and whether each site answers (read-only; --target this|T|U@H[:P])
  certs                   certificate expiry report for configured sites
  register-target U@H[:P] install SSH key on a new target and save it in targets.json
                          (name: REGISTER_NAME=<name>, default the host)
  help                    display this help

Options (anything omitted is asked interactively):
  --target this|T|U@H[:P] target machine ('this' = local host)
  --setup NAME            setup type (docker_stack, native_lemp)
  --site NAME             site domain (e.g. example.com)
  --branch NAME           git branch to deploy
  --site-user NAME|per-site  Linux users on the server: one user NAME for all sites, or one per site
                          (default: what the server has now, else per-site)
  --traffic LEVEL         traffic level (low, medium, high)
  --php VERSION           PHP version (8.0, 8.1, 8.2, 8.3, 8.4); for "server", one or more: 8.2,8.3
  --install PARTS         "server": parts to add or start, e.g. nginx,clickhouse,node or lemp (nginx, PHP,
                          Redis, MariaDB) or docker (the Docker stack); without -y one checklist asks
                          (native_lemp: nginx php mariadb mysql redis certbot clickhouse node;
                          docker_stack: mariadb certbot clickhouse node)
  --remove PARTS          "server": parts to stop, e.g. redis,mariadb or php-8.1 (one PHP version)
  --db-swap MODE          "server": --install mysql on a MariaDB server (or the other way round):
                            stop    stop the old one, keep its data folder (switching back uses it)
                            dump    remove the old one, keep a dump of every database in the snapshot
                            delete  remove the old one and all its data
                            both    keep both: the new one runs on 127.0.0.1:3307 (Docker container)
  --force                 "server": stop parts that sites on the server still use
  --snapshot ID           "rollback": the snapshot to return to (deploy.sh rollback lists them)
  --fw-action ACTION      "firewall": setup (default; installs CSF when missing), off, on, uninstall
  --fw-ports P            "firewall": open to everyone: ssh (all closed but SSH), web (+80,443),
                          cloudflare (80,443 only from Cloudflare), default (CSF's list) or 80,443,8080
  --fw-udp LIST|none      "firewall": UDP ports open to everyone
  --fw-ssh open|allowed   "firewall": SSH open to everyone (default) or only to the --fw-allow IPs
  --fw-allow IPS          "firewall": always allowed, every port (csf.allow); default: your IP
  --fw-ignore IPS         "firewall": never blocked by LFD (csf.ignore); default: the allowed IPs
  --fw-deny IPS           "firewall": always blocked (csf.deny)
  --fw-port-ip RULES      "firewall": ports for some IPs only: 3306:1.2.3.4,53/udp:5.6.7.8
  --fw-out all|default    "firewall": outgoing ports: all (default) or CSF's common list
  --fw-ping yes|no        "firewall": answer ping (default yes)
  --fw-ssh-limit N        "firewall": failed SSH logins before LFD blocks the IP (default 5, 0 = off)
  --fw-ssh-block B        "firewall": perm (default) or seconds
  --fw-email EMAIL|none   "firewall": where LFD sends alerts
  --fw-testing yes|no     "firewall": yes = stay in TESTING mode (rules cleared every 5 minutes)
  --env production|local  deployment environment
  --db-mode MODE          database mode (seed, import_backup, none for local; remote for production)
  --db-host HOST          production database host (saved per site; also --db-port, --db-name, --db-user)
                          (production password: asked, or DEPLOY_DB_PASSWORD)
  --db-backup PATH        .sql or .sql.gz dump for --db-mode import_backup (copied to data/backups/)
  --tls MODE              SSL certificate source:
                            none      plain HTTP
                            existing  files already on the target (--cert-path, --key-path)
                            paste     paste certificate and key in the terminal (interactive only)
                            certbot   free Let's Encrypt certificate (--certbot-email)
                            files     files on this machine (--cert-file, --cert-key)
                            keep      same as existing with /etc/nginx/cert/<site>/
  --cert-path PATH        certificate path on the target (when --tls existing)
  --key-path PATH         private key path on the target (when --tls existing)
  --certbot-email EMAIL   email for Let's Encrypt expiry notices (when --tls certbot)
  --cert-file PATH        certificate path on this machine (when --tls files)
  --cert-key PATH         private key path on this machine (when --tls files)
  --skip-repo-check       skip remote git ls-remote pre-check
  --server-refresh        run every server part (packages, docker stack, certbot) even when it is
                          up to date; normally a part only runs when it is new or its files changed
  --switch ACTION         when the target runs the other setup: move (move all its sites), move:a.com,b.com
                          (move these, close the rest), stop (close them all) or cancel
  --stack-config          docker_stack: ask the server settings again (allowed IPs, whitelist, webhook)
  --stack-admin-ips LIST  docker_stack: IPs allowed to open the sites ("1.2.3.4 5.6.7.8" or "1.2.3.4,5.6.7.8"),
                          or none = public
  --stack-whitelist-ips L docker_stack: IPs that skip the nginx rate limits
                          (Discord webhook for container alerts: DEPLOY_DISCORD_WEBHOOK environment variable)
  --check                 dry run: shows what would change (file diffs) and changes nothing
  -y, --yes               skip confirmation
  --ask-become            ask for sudo password on target
  --plain                 numbered plain prompts instead of whiptail menus (also DEPLOY_UI=plain);
                          menus are used when whiptail is installed and this runs in a terminal
  --verbose               show the output of every step while it runs
  --timings               list the slowest steps at the end
USAGE
}

parse_args() {
  while (($#)); do
    case $1 in
      --target)          TARGET=${2:?};      shift 2 ;;
      --setup)           SETUP=${2:?};       shift 2 ;;
      --site)            SITE=${2:?};        shift 2 ;;
      --branch)          CLI_BRANCH=${2:?};  shift 2 ;;
      --site-user)       CLI_SITE_USER=${2:?}; shift 2 ;;
      --traffic)         CLI_TRAFFIC=${2:?}; shift 2 ;;
      --php)             CLI_PHP=${2:?};     shift 2 ;;
      --env)             ENVIRONMENT=${2:?}; shift 2 ;;
      --db-mode)         DB_MODE=${2:?};     shift 2 ;;
      --db-host)         CLI_DB_HOST=${2:?}; shift 2 ;;
      --db-port)         CLI_DB_PORT=${2:?}; shift 2 ;;
      --db-name)         CLI_DB_NAME=${2:?}; shift 2 ;;
      --db-user)         CLI_DB_USER=${2:?}; shift 2 ;;
      --db-backup)       CLI_DB_BACKUP=${2:?}; shift 2 ;;
      --move-dump)       MOVE_DUMP=${2:?};   shift 2 ;;   # internal: import a dump that is already on the target
      --keep-db-password) KEEP_DB_PASSWORD=1; shift ;;     # internal: keep DB_PASSWORD from the site's .env
      --tls)             CLI_TLS=${2:?};     shift 2 ;;
      --install)         CLI_INSTALL=${2:?}; CLI_INSTALL=${CLI_INSTALL//,/ }; shift 2 ;;
      --remove)          CLI_REMOVE=${2:?};  shift 2 ;;
      --db-swap)         CLI_DB_SWAP=${2:?}; shift 2 ;;
      --snapshot)        CLI_SNAPSHOT=${2:?}; shift 2 ;;
      --force)           FORCE_REMOVE=1;     shift ;;
      --fw-action)       CLI_FW_ACTION=${2:?};  shift 2 ;;
      --fw-ports)        CLI_FW_PORTS=${2:?};   shift 2 ;;
      --fw-udp)          CLI_FW_UDP=${2:?};     shift 2 ;;
      --fw-ssh)          CLI_FW_SSH=${2:?};     shift 2 ;;
      --fw-allow)        CLI_FW_ALLOW=${2:?};   shift 2 ;;
      --fw-ignore)       CLI_FW_IGNORE=${2:?};  shift 2 ;;
      --fw-deny)         CLI_FW_DENY=${2:?};    shift 2 ;;
      --fw-port-ip)      CLI_FW_PORT_IP=${2:?}; shift 2 ;;
      --fw-out)          CLI_FW_OUT=${2:?};     shift 2 ;;
      --fw-ping)         CLI_FW_PING=${2:?};    shift 2 ;;
      --fw-ssh-limit)    CLI_FW_SSH_LIMIT=${2:?}; shift 2 ;;
      --fw-ssh-block)    CLI_FW_SSH_BLOCK=${2:?}; shift 2 ;;
      --fw-email)        CLI_FW_EMAIL=${2:?};   shift 2 ;;
      --fw-testing)      CLI_FW_TESTING=${2:?}; shift 2 ;;
      --cert-file)       CLI_CERT_FILE=${2:?}; shift 2 ;;
      --cert-key)        CLI_CERT_KEY=${2:?};  shift 2 ;;
      --cert-path)       CLI_CERT_PATH=${2:?}; shift 2 ;;
      --key-path)        CLI_KEY_PATH=${2:?};  shift 2 ;;
      --certbot-email)   CLI_CERTBOT_EMAIL=${2:?}; shift 2 ;;
      --skip-repo-check) SKIP_REPO_CHECK=1;  shift ;;
      --server-refresh)  SERVER_REFRESH=1;   shift ;;
      --switch)          SWITCH_ACTION=${2:?}; CLI_SWITCH=$2; [[ $SWITCH_ACTION != move[:=]* ]] || SWITCH_ACTION=${SWITCH_ACTION%%[:=]*}:list; shift 2 ;;
      --stack-config)    STACK_CONFIG=1; shift ;;
      --stack-admin-ips) CLI_STACK_ADMIN_IPS=${2:?}; CLI_STACK_ADMIN_IPS=${CLI_STACK_ADMIN_IPS//,/ }; shift 2 ;;
      --stack-whitelist-ips) CLI_STACK_WHITELIST_IPS=${2:?}; CLI_STACK_WHITELIST_IPS=${CLI_STACK_WHITELIST_IPS//,/ }; shift 2 ;;
      --check)           DRY_RUN=1;          shift ;;
      --plain)           PLAIN_UI=1;         shift ;;
      -y|--yes)          ASSUME_YES=1;       shift ;;
      --ask-become)      ASK_BECOME=1;       shift ;;
      -h|--help)         usage; exit 0 ;;
      --verbose)         VERBOSE=1;          shift ;;
      --timings)         SHOW_TIMINGS=1;     shift ;;
      -*)                die "Unknown option: $1 (see --help)" ;;
      *)                 POSITIONAL+=("$1"); shift ;;
    esac
  done
}

cmd_validate() {
  need_cmds jq python3 openssl
  validate_sites_json "${SITE:-}"
  info "Validation passed: sites.json and traffic.json are valid"
}

cmd_deploy() {
  need_cmds jq python3 flock openssl tar
  ensure_state_files
  [[ -z ${SITE:-} ]] || validate_sites_json "$SITE"
  umask 077; TMP_DIR=$(mktemp -d)

  pick_target; probe_target; pick_setup; handle_switch
  pick_stack_config
  pick_site
  # Deploying a site that ran on the old setup: carry its local database over (unless a seed or
  # another import was chosen), and make sure it is dumped before the old setup stops.
  DUMP_SITES=("${MOVE_SITES[@]}")
  if [[ " ${OLD_SITES[*]} " == *" $SITE "* ]]; then
    [[ " ${DUMP_SITES[*]} " == *" $SITE "* ]] || DUMP_SITES+=("$SITE")
    if [[ -z $MOVE_DUMP && ${DB_MODE:-none} == none && ${ENVIRONMENT:-local} == local ]]; then
      MOVE_DUMP="/var/lib/deployer/moves/$SITE.sql.gz"
    fi
  fi
  pick_site_user; pick_branch; pick_traffic; pick_php; pick_environment; pick_tls
  pick_redis_password deploy
  if [[ $ENVIRONMENT == production ]]; then MOVE_DUMP=''; fi   # production data lives on its own DB server
  validate_sites_json "$SITE"

  show_summary; confirm_run
  ui_screen_off   # the deploy's output goes to the terminal as it runs

  if ((! DRY_RUN)); then
    update_site_field "$SITE" branch "$BRANCH"
    update_site_field "$SITE" traffic "$TRAFFIC"
    update_site_field "$SITE" php_version "$PHP_VERSION"
  fi

  if [[ -z ${DEPLOYER_LOCK_HELD:-} ]]; then   # set for the per-site deploys of a move: the parent holds it
    mkdir -p "$DATA/.locks"
    exec {LOCK_FD}>"$DATA/.locks/target-$TARGET_KEY.lock"
    flock -n "$LOCK_FD" || die "Another deploy to '$TARGET_KEY' is already running"
  fi
  audit "START target=$TARGET_KEY site=$SITE setup=$SETUP branch=$BRANCH traffic=$TRAFFIC php=$PHP_VERSION env=$ENVIRONMENT db=$DB_MODE tls=$TLS_MODE dry_run=$DRY_RUN"

  load_git_key; build_vars
  local rc=0; run_engine || rc=$?
  audit "END target=$TARGET_KEY site=$SITE rc=$rc"
  # Saved only after success: a pasted certificate or a certbot one exists on the target only now
  if ((rc == 0 && ! DRY_RUN)); then update_site_tls_block "$SITE" "$TLS_MODE"; finish_git_key; fi
  if ((rc == 0)); then info "Done."; else warn "The deploy stopped with code $rc (log: $LOG_FILE)"; fi
  if ((rc == 0 && ! DRY_RUN && ${#MOVE_SITES[@]} > 0)); then deploy_moved_sites || rc=$?; fi
  return "$rc"
}

# After a switch: deploy each site chosen to move on the new setup, one after the other, with the
# settings saved in sites.json. Local databases come from the dumps taken before the old setup stopped.
deploy_moved_sites() {
  local d env tlsm rec_tls e args=() done_ok=() failed=() n=0 total=0
  for d in "${MOVE_SITES[@]}"; do [[ $d == "$SITE" ]] || total=$((total + 1)); done
  ((total > 0)) || return 0
  for d in "${MOVE_SITES[@]}"; do
    [[ $d == "$SITE" ]] && continue
    n=$((n + 1))
    env=$(echo "$SWITCH_SITES_JSON" | jq -r --arg d "$d" '.[] | select(.domain == $d) | .environment // "local"')
    rec_tls=$(echo "$SWITCH_SITES_JSON" | jq -r --arg d "$d" '.[] | select(.domain == $d) | .tls_mode // "none"')
    tlsm=$(site_field "$d" tls.mode)
    args=(--target "$TARGET" --setup "$SETUP" --site "$d" --branch "$(site_field "$d" branch)" --env "$env" -y)
    [[ -z $(site_field "$d" traffic) ]] || args+=(--traffic "$(site_field "$d" traffic)")
    if [[ $SETUP == native_lemp && -n $(site_field "$d" php_version) ]]; then args+=(--php "$(site_field "$d" php_version)"); fi
    case "${tlsm:-$rec_tls}" in
      certbot) args+=(--tls certbot); e=$(site_field "$d" tls.email); [[ -z $e ]] || args+=(--certbot-email "$e") ;;
      none)    args+=(--tls none) ;;
      *)       args+=(--tls keep) ;;   # the certificate is already in /etc/nginx/cert/<site>/ on the server
    esac
    if [[ $env == production ]]; then args+=(--keep-db-password); else args+=(--move-dump "/var/lib/deployer/moves/$d.sql.gz"); fi
    ((ASK_BECOME)) && args+=(--ask-become)
    printf '\n%s==> Moving %s to %s (%d of %d)%s\n' "$C_GRN" "$d" "$SETUP" "$n" "$total" "$C_OFF" >&2
    if DEPLOYER_LOCK_HELD=1 "$BASE/deploy.sh" "${args[@]}"; then done_ok+=("$d"); else failed+=("$d"); fi
  done
  printf '\n---- Move to %s ----\n' "$SETUP" >&2
  ((${#done_ok[@]} == 0)) || printf '  moved : %s\n' "${done_ok[*]}" >&2
  if ((${#failed[@]})); then
    printf '  FAILED: %s (still offline; database dumps kept in /var/lib/deployer/moves/ on the server)\n' "${failed[*]}" >&2
    printf '  Retry one with: ./deploy.sh --target %s --setup %s --site <site> --env <env> --db-mode import_backup ...\n' "$TARGET" "$SETUP" >&2
    return 1
  fi
  return 0
}

# ---------------------------------------------------------------- server stack: set up, change, roll back
# deploy.sh server: what a target runs, with or without sites. The checklist starts with what runs now;
# ticking adds or starts a part, unticking stops it (stopped and disabled: packages, config and data
# stay; Node.js is uninstalled). MariaDB <-> MySQL is a swap (asked: dump, delete, stop, or keep both
# with the second one on port 3307). A server without sites can also change setup (native_lemp <->
# docker_stack). Every change starts with a snapshot on the server; deploy.sh rollback returns to one.
SERVER_PART_NAMES=(nginx php mariadb mysql redis certbot clickhouse node)
STACK_REMOVE=() DB_SWAP='' DB_SWAP_MODE='' SECOND_DB_KIND='' RESTORE_SNAPSHOT='' SNAPSHOT_LABEL='' STACK_SWITCH=0 ROLLBACK_DB_SOURCE=''
CLICKHOUSE_PASSWORD=${DEPLOY_CLICKHOUSE_PASSWORD:-}

# pick_clickhouse_password: when ClickHouse gets installed: your own password for its "default" user,
# or a random one (both saved in /etc/deployer/clickhouse_password). -y: DEPLOY_CLICKHOUSE_PASSWORD.
check_ch_password() {
  [[ ${#1} -ge 8 && ! $1 =~ [[:space:]\'\"\\\<\>\&] ]] && return 0
  echo "At least 8 characters, without spaces, quotes, backslashes, < > or &"; return 1
}
pick_clickhouse_password() {
  [[ " ${SERVER_PARTS[*]} " == *" clickhouse "* ]] || return 0
  if [[ -n $CLICKHOUSE_PASSWORD ]]; then
    check_ch_password "$CLICKHOUSE_PASSWORD" >/dev/null || die "DEPLOY_CLICKHOUSE_PASSWORD: $(check_ch_password "$CLICKHOUSE_PASSWORD" || true)"
    return 0
  fi
  interactive || return 0
  local c p1 p2 err
  if [[ $(part_now clickhouse) != absent ]]; then
    ui_menu c "ClickHouse is installed. Its default user's password:" keep \
      keep "Keep it (sudo cat /etc/deployer/clickhouse_password on the server)" \
      own  "Set a new password"
  else
    ui_menu c "Password for ClickHouse's default user:" own \
      own    "Type my own password" \
      random "Make a random one (saved in /etc/deployer/clickhouse_password)"
  fi
  [[ $c == own ]] || return 0
  while true; do
    ui_secret p1 "ClickHouse password for the default user (at least 8 characters)"
    if ! err=$(check_ch_password "$p1"); then ui_error "$err"; continue; fi
    ui_secret p2 "The same password again"
    [[ $p1 == "$p2" ]] && break
    ui_error "The two passwords are not the same."
  done
  CLICKHOUSE_PASSWORD=$p1
}

# pick_redis_password server|deploy: the Redis password (native: /etc/deployer/redis_password, docker
# stack: requirepass in /opt/docker-stack/redis/redis.conf). When Redis is new: your own or a random
# one; "deploy.sh server" on a server that has it: keep it or set a new one (every site's .env on the
# server gets the new one right away), or no password at all ("none": Redis listens on 127.0.0.1 only).
# -y: DEPLOY_REDIS_PASSWORD (a password, or none).
REDIS_PASSWORD_NEW=${DEPLOY_REDIS_PASSWORD:-}
check_redis_password() {
  [[ $1 =~ ^[A-Za-z0-9._@%+=:,!^*~-]{8,}$ ]] && return 0
  echo "At least 8 characters: letters, digits and . _ @ % + = : , ! ^ * ~ - (no spaces, quotes, # or \$)"; return 1
}
redis_now() {
  if [[ $SETUP == docker_stack ]]; then
    if ((STACK_CONFIGURED && ! STACK_SWITCH)); then echo on; else echo absent; fi
  else part_now redis; fi
}
redis_password_file() { [[ $SETUP == docker_stack ]] && echo "$stack_dir_ui/redis/redis.conf (requirepass)" || echo /etc/deployer/redis_password; }
stack_dir_ui=/opt/docker-stack
pick_redis_password() {
  if [[ $1 == server ]]; then
    [[ $SETUP == docker_stack || " ${SERVER_PARTS[*]} " == *" redis "* ]] || return 0
  else
    [[ $(redis_now) == absent ]] || return 0   # a deploy only asks when it installs Redis
  fi
  if [[ -n $REDIS_PASSWORD_NEW ]]; then
    [[ $REDIS_PASSWORD_NEW == none ]] || check_redis_password "$REDIS_PASSWORD_NEW" >/dev/null \
      || die "DEPLOY_REDIS_PASSWORD: $(check_redis_password "$REDIS_PASSWORD_NEW" || true), or none (no password)"
    return 0
  fi
  interactive || return 0
  local c p1 p2 err
  if [[ $(redis_now) != absent ]]; then
    ui_menu c "Redis is installed. Its password:" keep \
      keep "Keep it as it is (sudo cat $(redis_password_file) on the server)" \
      own  "Set a new password (every site's .env on the server gets it)" \
      none "No password (Redis listens on 127.0.0.1 only; any program on the server can use it)"
  else
    ui_menu c "Password for Redis:" own \
      own    "Type my own password" \
      random "Make a random one (saved in $(redis_password_file))" \
      none   "No password (Redis listens on 127.0.0.1 only; any program on the server can use it)"
  fi
  if [[ $c == none ]]; then REDIS_PASSWORD_NEW=none; return 0; fi
  [[ $c == own ]] || return 0
  while true; do
    ui_secret p1 "Redis password (at least 8 characters)"
    if ! err=$(check_redis_password "$p1"); then ui_error "$err"; continue; fi
    ui_secret p2 "The same password again"
    [[ $p1 == "$p2" ]] && break
    ui_error "The two passwords are not the same."
  done
  REDIS_PASSWORD_NEW=$p1
}
redis_summary() {
  if [[ $REDIS_PASSWORD_NEW == none ]]; then
    printf "  Redis       : NO password (127.0.0.1 only)%s\n" "$([[ $(redis_now) == absent ]] || echo "; every site's .env on the server gets REDIS_PASSWORD=null now")"
  elif [[ -n $REDIS_PASSWORD_NEW ]]; then
    if [[ $(redis_now) == absent ]]; then printf '  Redis       : the password you typed\n'
    else printf "  Redis       : NEW password; every site's .env on the server gets it now\n"; fi
  elif [[ $(redis_now) == absent ]]; then printf '  Redis       : a random password (%s)\n' "$(redis_password_file)"
  fi
}

# server_part_label PART: the text shown for a part
server_part_label() {
  case $1 in
    nginx)      echo "nginx web server" ;;
    php)        echo "PHP-FPM + Composer (versions next)" ;;
    mariadb)    echo "MariaDB server + mariadb-client" ;;
    mysql)      echo "MySQL server + mysql-client" ;;
    redis)      echo "Redis" ;;
    certbot)    echo "certbot, Let's Encrypt (needs nginx)" ;;
    clickhouse) echo "ClickHouse 26.7.5.10" ;;
    node)       echo "Node.js 22 LTS + npm" ;;
    second-db)  echo "$(db_name "${SECOND_DB_KIND:-$PROBE_SECOND_KIND}") on port 3307 (container)" ;;
    stack-mariadb) echo "the stack's MariaDB container" ;;
    php-*)      echo "PHP ${1#php-}" ;;
    *)          echo "$1" ;;
  esac
}
# part_now PART: on, off or absent on the target now (the second database counts as its kind)
part_now() {
  local p=$1 s
  if [[ $SETUP == docker_stack && $p == mariadb ]]; then p=stack-mariadb; fi
  s=$(jq -r --arg p "$p" '.[$p] // "absent"' <<< "$PROBE_PARTS")
  if [[ $s == absent && $SETUP == native_lemp && ($1 == mysql || $1 == mariadb) && $PROBE_SECOND_KIND == "$1" ]]; then
    s=$(jq -r '.["second-db"] // "absent"' <<< "$PROBE_PARTS")
  fi
  if [[ $1 == php ]]; then s=$(jq -r 'if ([.[] | select(. == "on")] | length) > 0 then "on" elif length > 0 then "off" else "absent" end' <<< "$PROBE_PHP_STATES"); fi
  # on a setup switch the old setup's parts are closed: only host parts carry over
  if ((STACK_SWITCH)) && [[ ! $1 =~ ^(clickhouse|node)$ ]]; then s=absent; fi
  echo "$s"
}
native_db_now() {
  local k; for k in mariadb mysql; do [[ $(jq -r --arg k "$k" '.[$k] // "absent"' <<< "$PROBE_PARTS") == absent ]] || { echo "$k"; return 0; }; done
}
db_name() { case $1 in mariadb) echo MariaDB ;; mysql) echo MySQL ;; *) echo "$1" ;; esac; }
state_label() { case $1 in on) echo '  (running)' ;; off) echo '  (stopped)' ;; esac; }

# server_parts_problem: why the chosen SERVER_PARTS cannot work together (empty when they can)
server_parts_problem() {
  local has=" ${SERVER_PARTS[*]} " cur
  cur=$(native_db_now); ((STACK_SWITCH)) && cur=''
  if [[ $has == *" certbot "* && $SETUP == native_lemp && $has != *" nginx "* ]]; then
    echo "certbot needs nginx (Let's Encrypt checks the domain through nginx). Choose nginx too."
  elif [[ $SETUP == native_lemp && $has == *" mariadb "* && $has == *" mysql "* && -z $cur ]]; then
    echo "Choose MariaDB or MySQL. When one of them runs, the other can be added next to it on port 3307."
  fi
}

# pick_server_universal: one checklist to build the server's stack: the Docker stack, the LEMP preset,
# or any mix of single services (nginx, PHP, MariaDB or MySQL, Redis, certbot, ClickHouse, Node.js),
# plus the CSF firewall. Sets SETUP and SERVER_PARTS (the checklist in pick_stack_parts is skipped)
# and SERVER_WANT_FIREWALL. Ticked = what the server runs now.
SERVER_UNIVERSAL=0 SERVER_WANT_FIREWALL=0
pick_server_universal() {
  local args=() picks p st def problem has cur_setup=${TARGET_MARKER:-native_lemp} fw_on=off
  STACK_SWITCH=0
  while true; do
    args=()
    def=off; [[ $cur_setup != docker_stack ]] || def=on
    args+=(docker "Docker stack: nginx, PHP 8.2 and Redis in containers$( [[ $def == on ]] && echo '  (running)' || true)" "$def")
    args+=(lemp "LEMP: nginx + PHP + MariaDB + Redis (native; MySQL instead when ticked below)" off)
    for p in "${SERVER_PART_NAMES[@]}"; do
      st=$(SETUP=$cur_setup part_now "$p")
      if [[ $cur_setup == docker_stack && $p =~ ^(nginx|php|redis|mysql)$ ]]; then st=absent; fi
      def=off; [[ $st != on ]] || def=on
      case $p in
        nginx) args+=("$p" "nginx $(state_label "$st")" "$def") ;;
        php)   args+=("$p" "PHP-FPM + Composer (versions asked next)$(state_label "$st")" "$def") ;;
        mariadb) args+=("$p" "MariaDB$( [[ $cur_setup == docker_stack ]] && echo ' (with the Docker stack: its MariaDB container)' || true)$(state_label "$st")" "$def") ;;
        mysql) args+=("$p" "MySQL 8 (native)$(state_label "$st")" "$def") ;;
        redis) args+=("$p" "Redis $(state_label "$st")" "$def") ;;
        *)     args+=("$p" "$(server_part_label "$p")$(state_label "$st")" "$def") ;;
      esac
    done
    [[ ${FW[installed]:-} != yes ]] || fw_on=on
    args+=(firewall "CSF firewall (its questions come after the server is set up)$( [[ $fw_on == on ]] && echo '  (installed)' || true)" off)
    ui_checklist picks "Build the stack for $TARGET_LABEL: tick everything it should run."$'\n'"Unticking a running part stops it (packages and data stay)." "${args[@]}"
    has=" $picks "
    SERVER_WANT_FIREWALL=0; [[ $has != *" firewall "* ]] || SERVER_WANT_FIREWALL=1
    SERVER_PARTS=()
    problem=''
    if [[ $has == *" docker "* ]]; then
      SETUP=docker_stack
      for p in nginx php redis mysql lemp; do
        [[ $has != *" $p "* ]] || { problem="The Docker stack already runs nginx, PHP 8.2 and Redis in containers, and its database is MariaDB. Untick nginx, PHP, Redis, MySQL and LEMP, or untick the Docker stack."; break; }
      done
      for p in mariadb certbot clickhouse node; do [[ $has != *" $p "* ]] || SERVER_PARTS+=("$p"); done
    else
      SETUP=native_lemp
      if [[ $has == *" lemp "* ]]; then
        has+="nginx php redis "; [[ $has == *" mysql "* ]] || has+="mariadb "
      fi
      for p in "${SERVER_PART_NAMES[@]}"; do [[ $has != *" $p "* ]] || SERVER_PARTS+=("$p"); done
    fi
    if [[ -z $problem ]] && ((${#SERVER_PARTS[@]} == 0)) && [[ $SETUP == native_lemp ]]; then
      local running=no; for p in "${SERVER_PART_NAMES[@]}"; do [[ $(SETUP=$cur_setup part_now "$p") != on ]] || running=yes; done
      [[ $cur_setup != docker_stack ]] || running=yes
      if [[ $running == no ]]; then
        ((SERVER_WANT_FIREWALL)) && { SERVER_UNIVERSAL=2; return 0; }   # only the firewall
        problem="Tick at least one thing to install."
      fi
    fi
    [[ -n $problem ]] || problem=$(server_parts_problem)
    [[ -z $problem ]] && break
    ui_error "$problem"
  done
  SERVER_UNIVERSAL=1
}

# pick_stack_parts: SERVER_PARTS and SERVER_PHP = what the target should run
pick_stack_parts() {
  local valid=() picks='' p args=() st def problem nothing
  if [[ $SETUP == docker_stack ]]; then valid=(mariadb certbot clickhouse node); else valid=("${SERVER_PART_NAMES[@]}"); fi
  if ((SERVER_UNIVERSAL)); then
    :   # chosen already (pick_server_universal)
  elif [[ -n $CLI_INSTALL || -n $CLI_REMOVE ]]; then
    # the parts that run now, plus --install, minus --remove
    for p in "${valid[@]}"; do [[ $(part_now "$p") != on ]] || SERVER_PARTS+=("$p"); done
    for p in $CLI_INSTALL; do
      [[ $SETUP != docker_stack || ! $p =~ ^(nginx|php|redis)$ ]] || continue   # always in the stack
      [[ " ${valid[*]} " == *" $p "* ]] || die "--install: unknown part '$p' for $SETUP (valid: ${valid[*]})"
      [[ " ${SERVER_PARTS[*]} " == *" $p "* ]] || SERVER_PARTS+=("$p")
    done
    for p in ${CLI_REMOVE//,/ }; do
      [[ $p == php-* ]] && continue
      [[ " ${valid[*]} " == *" $p "* ]] || die "--remove: unknown part '$p' for $SETUP (valid: ${valid[*]}, or php-8.x for one PHP version)"
      local keep=(); for c in "${SERVER_PARTS[@]}"; do [[ $c == "$p" ]] || keep+=("$c"); done; SERVER_PARTS=("${keep[@]}")
    done
    # --install mysql on a MariaDB server (or the other way round) swaps them unless --db-swap both
    local cur; cur=$(native_db_now)
    if [[ $SETUP == native_lemp && -n $cur && $CLI_DB_SWAP != both && " $CLI_INSTALL " == *" $([[ $cur == mariadb ]] && echo mysql || echo mariadb) "* ]]; then
      local keep=(); for c in "${SERVER_PARTS[@]}"; do [[ $c == "$cur" ]] || keep+=("$c"); done; SERVER_PARTS=("${keep[@]}")
    fi
    problem=$(server_parts_problem); [[ -z $problem ]] || die "$problem"
  elif [[ -n $REDIS_PASSWORD_NEW ]] && ! interactive; then
    # -y with only DEPLOY_REDIS_PASSWORD: the parts stay as they are, Redis gets the new password
    for p in "${valid[@]}"; do [[ $(part_now "$p") != on ]] || SERVER_PARTS+=("$p"); done
    [[ $SETUP == docker_stack || " ${SERVER_PARTS[*]} " == *" redis "* ]] || die "DEPLOY_REDIS_PASSWORD: Redis does not run on $TARGET_LABEL (add --install redis)"
  elif ! interactive; then
    die "deploy.sh server with -y needs --install PARTS and/or --remove PARTS (${valid[*]}), e.g. --install mariadb,redis (or only DEPLOY_REDIS_PASSWORD=... for a new Redis password)"
  else
    nothing=yes; for p in "${valid[@]}"; do [[ $(part_now "$p") == absent ]] || nothing=no; done
    while true; do
      args=()
      for p in "${valid[@]}"; do
        st=$(part_now "$p") def=off
        if [[ $st == on ]] || { [[ $nothing == yes && $SETUP == native_lemp ]] && [[ $p =~ ^(nginx|php|mariadb|redis)$ ]]; }; then def=on; fi
        [[ $SETUP != docker_stack || $p != mariadb || $nothing != yes ]] || def=on
        local extra=''; [[ $p != "$PROBE_SECOND_KIND" || $SETUP != native_lemp || $(native_db_now) == "$p" || $(jq -r '.["second-db"] // "absent"' <<< "$PROBE_PARTS") == absent ]] || extra=' on port 3307'
        args+=("$p" "$(server_part_label "$p")$(state_label "$st")$extra" "$def")
      done
      if [[ $SETUP == docker_stack ]]; then
        ui_checklist picks "The docker stack (nginx, PHP 8.2, Redis) always runs. Also:"$'\n'"Unticking a running part stops it (its data stays)." "${args[@]}"
      else
        ui_checklist picks "What should $TARGET_LABEL run?"$'\n'"Unticking a running part stops it (packages and data stay)." "${args[@]}"
      fi
      read -ra SERVER_PARTS <<< "$picks"
      problem=$(server_parts_problem)
      [[ -z $problem ]] && break
      ui_error "$problem"
    done
  fi
  if [[ $SETUP == docker_stack ]]; then
    SERVER_PARTS=(nginx php redis "${SERVER_PARTS[@]}"); SERVER_PHP=(8.2)
    return 0
  fi
  [[ " ${SERVER_PARTS[*]} " == *" php "* ]] || { SERVER_PHP=(); return 0; }

  # PHP versions: --php 8.2,8.3, else asked (running ones ticked, else 8.2)
  local v on_php
  on_php=$(jq -r '[to_entries[] | select(.value == "on") | .key] | join(" ")' <<< "$PROBE_PHP_STATES")
  ((STACK_SWITCH)) && on_php=''
  if [[ -n $CLI_PHP ]]; then
    for v in ${CLI_PHP//,/ }; do
      [[ " ${PHP_VERSIONS[*]} " == *" $v "* ]] || die "--php: unsupported version '$v' (${PHP_VERSIONS[*]})"
      SERVER_PHP+=("$v")
    done
  elif ! interactive; then
    read -ra SERVER_PHP <<< "${on_php:-8.2}"
    for v in ${CLI_REMOVE//,/ }; do
      [[ $v == php-* ]] || continue
      local keep=(); for c in "${SERVER_PHP[@]}"; do [[ $c == "${v#php-}" ]] || keep+=("$c"); done; SERVER_PHP=("${keep[@]}")
    done
    ((${#SERVER_PHP[@]})) || die "--remove would stop every PHP version; use --remove php for that."
  else
    while true; do
      args=()
      for v in "${PHP_VERSIONS[@]}"; do
        st=$(jq -r --arg v "$v" '.[$v] // "absent"' <<< "$PROBE_PHP_STATES"); ((STACK_SWITCH)) && st=absent
        def=off
        if [[ $st == on ]] || { [[ -z $on_php ]] && [[ $v == 8.2 ]]; }; then def=on; fi
        args+=("$v" "PHP $v$(state_label "$st")" "$def")
      done
      ui_checklist picks "PHP versions (each runs its own PHP-FPM; unticking a running one stops it):" "${args[@]}"
      read -ra SERVER_PHP <<< "$picks"
      ((${#SERVER_PHP[@]})) && break
      ui_error "Choose at least one PHP version (untick PHP on the first screen to stop PHP)."
    done
  fi
}

# plan_stack_change: from SERVER_PARTS/SERVER_PHP and what runs now: STACK_REMOVE, the database swap
# (DB_SWAP, DB_SWAP_MODE, asked when not given) and SECOND_DB_KIND
plan_stack_change() {
  local p v cur new has st
  STACK_REMOVE=() DB_SWAP='' SECOND_DB_KIND=''
  has=" ${SERVER_PARTS[*]} "
  if [[ $SETUP == native_lemp ]] && ! ((STACK_SWITCH)); then
    cur=$(native_db_now)
    for new in mariadb mysql; do [[ $new == "$cur" || $has != *" $new "* ]] || break; new=''; done
    if [[ -n $cur && -n $new ]]; then
      if [[ $has == *" $cur "* ]]; then
        SECOND_DB_KIND=$new     # both ticked: the new one runs next to it on 3307
      else
        DB_SWAP_MODE=${DB_SWAP_MODE:-$CLI_DB_SWAP}
        if [[ -z $DB_SWAP_MODE ]]; then
          interactive || die "$TARGET_LABEL runs $(db_name "$cur"); choosing $(db_name "$new") needs --db-swap dump|delete|stop|both"
          ui_menu DB_SWAP_MODE "$(db_name "$cur") runs on $TARGET_LABEL and $(db_name "$new") should replace it."$'\n'"What happens to $(db_name "$cur")?" stop \
            stop   "Just stop $(db_name "$cur") and start $(db_name "$new") (its data folder is kept; switching back uses it again)" \
            dump   "Remove $(db_name "$cur"), keep a dump of all its databases (in the snapshot)" \
            delete "Remove $(db_name "$cur") and all its data" \
            both   "Keep both: $(db_name "$cur") stays on 3306, $(db_name "$new") runs on 3307 (Docker container)"
        fi
        [[ $DB_SWAP_MODE =~ ^(stop|dump|delete|both|restore)$ ]] || die "--db-swap: '$DB_SWAP_MODE' is not dump, delete, stop or both"
        if [[ $DB_SWAP_MODE == both ]]; then SECOND_DB_KIND=$new SERVER_PARTS+=("$cur") DB_SWAP_MODE=''
        else DB_SWAP="$cur>$new"; fi
      fi
    fi
    # the second database: it keeps running while its kind stays ticked next to the native one
    if [[ -z $SECOND_DB_KIND && -n $PROBE_SECOND_KIND && $has == *" $PROBE_SECOND_KIND "* && $PROBE_SECOND_KIND != "$cur" && -z $DB_SWAP ]]; then
      SECOND_DB_KIND=$PROBE_SECOND_KIND
    fi
    if [[ -n $SECOND_DB_KIND ]]; then
      local keep=(); for p in "${SERVER_PARTS[@]}"; do [[ $p == "$SECOND_DB_KIND" ]] || keep+=("$p"); done
      SERVER_PARTS=("${keep[@]}" second-db)
    fi
    [[ $(jq -r '.["second-db"] // "absent"' <<< "$PROBE_PARTS") != on || -n $SECOND_DB_KIND ]] || STACK_REMOVE+=(second-db)
  fi
  has=" ${SERVER_PARTS[*]} "
  for p in nginx redis mariadb mysql certbot clickhouse node; do
    ((STACK_SWITCH)) && [[ ! $p =~ ^(clickhouse|node)$ ]] && continue
    if [[ $SETUP == docker_stack && $p =~ ^(nginx|redis|mysql)$ ]]; then continue; fi
    st=$(jq -r --arg p "$p" '.[$p] // "absent"' <<< "$PROBE_PARTS")
    if [[ $SETUP == docker_stack && $p == mariadb ]]; then
      st=$(jq -r '.["stack-mariadb"] // "absent"' <<< "$PROBE_PARTS")
      [[ $st != on || $has == *" mariadb "* ]] || STACK_REMOVE+=(stack-mariadb)
      continue
    fi
    [[ $st == on && $has != *" $p "* ]] || continue
    [[ -z $DB_SWAP || $p != "${DB_SWAP%%>*}" ]] || continue   # handled by the swap
    STACK_REMOVE+=("$p")
  done
  if [[ $SETUP == native_lemp ]] && ! ((STACK_SWITCH)); then
    for v in $(jq -r 'to_entries[] | select(.value == "on") | .key' <<< "$PROBE_PHP_STATES"); do
      [[ " ${SERVER_PHP[*]} " == *" $v "* ]] || STACK_REMOVE+=("php-$v")
    done
  fi
}

# check_stack_removals: a part that a site on the target still needs is stopped only when confirmed
check_stack_removals() {
  local p need=() sites
  sites=$(jq -r '[.[] | select((.status // "active") != "stopped")] | length' <<< "$PROBE_SITES")
  ((sites > 0)) || return 0
  for p in "${STACK_REMOVE[@]}" ${DB_SWAP:+${DB_SWAP%%>*}}; do
    case $p in
      nginx|redis|stack-mariadb|mariadb|mysql) need+=("$p") ;;
      php-*) [[ $(jq -r --arg v "${p#php-}" '[.[] | select((.status // "active") != "stopped" and .php_version == $v)] | length' <<< "$PROBE_SITES") == 0 ]] || need+=("$p") ;;
    esac
  done
  ((${#need[@]})) || return 0
  local list; list=$(jq -r '[.[] | select((.status // "active") != "stopped") | .domain] | join(", ")' <<< "$PROBE_SITES")
  local msg="Sites on $TARGET_LABEL still use: ${need[*]}"$'\n'"($list)"$'\n\n'"They stop working until these run again."
  if ((FORCE_REMOVE)); then warn "$msg"; return 0; fi
  interactive || die "$msg Add --force to do it anyway."
  ui_yesno "$msg"$'\n\n'"Stop them anyway?" no || ui_cancelled
}

show_server_summary() {
  local p list=() add=() start=() dry=no st label
  ((DRY_RUN)) && dry=yes
  for p in "${SERVER_PARTS[@]}"; do
    [[ $SETUP != docker_stack || ! $p =~ ^(nginx|php|redis)$ ]] || continue
    case $p in
      php)
        local v; for v in "${SERVER_PHP[@]}"; do
          st=$(jq -r --arg v "$v" '.[$v] // "absent"' <<< "$PROBE_PHP_STATES"); ((STACK_SWITCH)) && st=absent
          case $st in on) list+=("PHP $v") ;; off) start+=("PHP $v") ;; *) add+=("PHP $v") ;; esac
        done
        continue ;;
      second-db) st=$(jq -r '.["second-db"] // "absent"' <<< "$PROBE_PARTS"); [[ $PROBE_SECOND_KIND == "$SECOND_DB_KIND" ]] || st=absent ;;
      *) st=$(part_now "$p") ;;
    esac
    [[ -z $DB_SWAP || $p != "${DB_SWAP#*>}" ]] || continue
    if [[ $SETUP == docker_stack && $p == mariadb ]]; then label=$(server_part_label stack-mariadb)
    else label=$(server_part_label "$p"); fi
    label=${label%% (*}; label=${label%%,*}
    case $st in on) list+=("$label") ;; off) start+=("$label") ;; *) add+=("$label") ;; esac
  done
  local stop=(); for p in "${STACK_REMOVE[@]}"; do label=$(server_part_label "$p"); stop+=("${label%% (*}"); done
  j() { local IFS=,; echo "$*" | sed 's/,/, /g'; }
  SUMMARY_TEXT=$({
    printf 'Server stack\n\n'
    printf '  Target      : %s\n' "$TARGET_LABEL"
    if ((STACK_SWITCH)); then printf '  Setup       : %s -> %s (the %s services are stopped)\n' "$TARGET_MARKER" "$SETUP" "$TARGET_MARKER"
    else printf '  Setup       : %s\n' "$SETUP"; fi
    [[ $SETUP != docker_stack ]] || printf '  Stack       : nginx, PHP 8.2, Redis containers\n'
    ((${#list[@]} == 0))  || printf '  Keep        : %s\n' "$(j "${list[@]}")"
    ((${#add[@]} == 0))   || printf '  Install     : %s\n' "$(j "${add[@]}")"
    ((${#start[@]} == 0)) || printf '  Start again : %s\n' "$(j "${start[@]}")"
    ((${#stop[@]} == 0))  || printf '  Stop        : %s (packages and data stay)\n' "$(j "${stop[@]}")"
    if [[ -n $DB_SWAP ]]; then
      local o=${DB_SWAP%%>*} n=${DB_SWAP#*>}
      case $DB_SWAP_MODE in
        stop)    printf '  Database    : %s -> %s; %s data folder kept\n' "$(db_name "$o")" "$(db_name "$n")" "$(db_name "$o")'s" ;;
        dump)    printf '  Database    : %s -> %s; %s removed, every database dumped first\n' "$(db_name "$o")" "$(db_name "$n")" "$(db_name "$o")" ;;
        delete)  printf '  Database    : %s -> %s; %s and ALL ITS DATA deleted\n' "$(db_name "$o")" "$(db_name "$n")" "$(db_name "$o")" ;;
        restore) printf '  Database    : %s -> %s; %s data folder kept; %s\n' "$(db_name "$o")" "$(db_name "$n")" "$(db_name "$o")'s" \
                   "$(case $ROLLBACK_DB_SOURCE in folder) echo "$(db_name "$n")'s kept data folder is used again" ;;
                      dumps) echo "the snapshot's dumps of $(db_name "$n") are imported" ;;
                      *) echo "$(db_name "$n") STARTS EMPTY (its data was deleted)" ;; esac)" ;;
      esac
      [[ $DB_SWAP_MODE == restore ]] || printf '                %s starts empty unless it ran here before; redeploy local sites\n' "$(db_name "$n")"
    fi
    [[ -z $SECOND_DB_KIND ]] || printf '  Second DB   : %s on 127.0.0.1:3307 (container), next to %s on 3306\n' "$(db_name "$SECOND_DB_KIND")" "$(db_name "$(native_db_now)")"
    ((${#list[@]} + ${#add[@]} + ${#start[@]} + ${#stop[@]}))  || [[ -n $DB_SWAP ]] || printf '  Change      : nothing (all parts are checked and kept up to date)\n'
    if [[ " ${SERVER_PARTS[*]} " == *" clickhouse "* ]]; then
      if [[ -n $CLICKHOUSE_PASSWORD ]]; then printf '  ClickHouse  : default user, the password you typed\n'
      elif [[ $(part_now clickhouse) == absent ]]; then printf '  ClickHouse  : default user, a random password (/etc/deployer/clickhouse_password)\n'; fi
    fi
    if [[ $SETUP == docker_stack || " ${SERVER_PARTS[*]} " == *" redis "* ]]; then redis_summary; fi
    printf '  Snapshot    : taken first on the server; undo with: deploy.sh rollback\n'
    printf '  Dry run     : %s\n' "$dry"
  })
  printf '\n%s\n\n' "$SUMMARY_TEXT" >&2
}

build_server_vars() {
  local bundle=$TMP_DIR/bundle comps=()
  rm -rf "$bundle"; mkdir -p "$bundle/files"
  VARS_FILE=$bundle/vars.sh
  q() { printf '%s=%q\n' "$1" "$2"; }
  qa() { local n=$1; shift; printf '%s=(' "$n"; (($# == 0)) || printf '%q ' "$@"; printf ')\n'; }
  comps=("${SERVER_PARTS[@]}")
  [[ " ${comps[*]} " == *" php "* ]] || ((${#SERVER_PHP[@]} == 0)) || [[ $SETUP == docker_stack ]] || comps+=(php)
  {
    echo "# vars for a server stack change (no site), written by deploy.sh $(date '+%F %T'). Removed after the run."
    q server_only yes
    qa server_components "${comps[@]}"
    qa server_php_versions "${SERVER_PHP[@]}"
    qa stack_remove "${STACK_REMOVE[@]}"
    q db_swap "$DB_SWAP"; q db_swap_mode "$DB_SWAP_MODE"; q second_db_kind "$SECOND_DB_KIND"
    q restore_snapshot "$RESTORE_SNAPSHOT"; q snapshot_label "${SNAPSHOT_LABEL:-stack change}"
    q clickhouse_password "$CLICKHOUSE_PASSWORD"
    q redis_password_new "$REDIS_PASSWORD_NEW"
    q setup_type "$SETUP"
    # the site settings are empty: no site is deployed
    q site_domain ''; qa site_aliases; q linux_user ''; q site_id ''; q site_user_mode ''
    q php_version "${SERVER_PHP[0]:-}"
    q deploy_env local; q tls_mode none; q db_mode none
    q tls_cert_path ''; q tls_key_path ''; q certbot_email ''
    q switch_mode "$( ((STACK_SWITCH)) && echo stop || echo none)"; q switch_from "${TARGET_MARKER:-}"; q switch_to "$SETUP"
    q stack_configure "$( ((STACK_CONFIGURE)) && echo true || echo false)"
    q server_refresh "$( ((SERVER_REFRESH)) && echo true || echo false)"
    # shellcheck disable=SC2086
    qa stack_admin_ips $STACK_ADMIN_IPS
    # shellcheck disable=SC2086
    qa stack_whitelist_ips $STACK_WHITELIST_IPS
    q discord_webhook "${DEPLOY_DISCORD_WEBHOOK:-}"
    q DRY_RUN "$DRY_RUN"
    q VERBOSE "$VERBOSE"
    q SHOW_TIMINGS "$SHOW_TIMINGS"
    q ENGINE_COLOR "$( [[ -t 1 ]] && echo 1 || echo 0)"
  } > "$VARS_FILE"
  chmod 0600 "$VARS_FILE"
}

# check_stack_switch: SETUP differs from the target's setup: allowed only when it has no sites
check_stack_switch() {
  STACK_SWITCH=0
  [[ -n $TARGET_MARKER && $TARGET_MARKER != "$SETUP" ]] || return 0
  local n; n=$(jq -r '[.[] | select((.status // "active") != "stopped")] | length' <<< "$PROBE_SITES")
  if ((n > 0)); then
    die "$TARGET_LABEL runs $TARGET_MARKER with $n site(s). Moving them to $SETUP is done with a site deploy: deploy.sh --setup $SETUP --switch move|stop ..."
  fi
  STACK_SWITCH=1
}

# run_stack_change TITLE: lock, audit and run the engine for SERVER_PARTS / STACK_REMOVE / DB_SWAP
run_stack_change() {
  mkdir -p "$DATA/.locks"
  exec {LOCK_FD}>"$DATA/.locks/target-$TARGET_KEY.lock"
  flock -n "$LOCK_FD" || die "Another deploy to '$TARGET_KEY' is already running"
  audit "START $1 target=$TARGET_KEY setup=$SETUP parts=${SERVER_PARTS[*]} php=${SERVER_PHP[*]} remove=${STACK_REMOVE[*]} db_swap=$DB_SWAP/$DB_SWAP_MODE second_db=$SECOND_DB_KIND snapshot=$RESTORE_SNAPSHOT dry_run=$DRY_RUN"
  build_server_vars
  local rc=0; run_engine || rc=$?
  audit "END $1 target=$TARGET_KEY rc=$rc"
  if ((rc == 0 && DRY_RUN)); then
    info "Dry run done: nothing was changed."
  elif ((rc == 0)); then
    info "Done. Undo this change with: ./deploy.sh rollback --target $TARGET"
  else
    warn "The $1 stopped with code $rc (log: $LOG_FILE). The snapshot taken first is listed by: ./deploy.sh rollback --target $TARGET"
  fi
  return "$rc"
}

cmd_server() {
  need_cmds jq python3 flock tar
  ensure_state_files
  umask 077; TMP_DIR=$(mktemp -d)
  UI_ASK_WHERE="Set up or change which machine?"
  pick_target; probe_target
  # --install docker / lemp: the Docker stack, or nginx + PHP + Redis + MariaDB (MySQL when given)
  if [[ " $CLI_INSTALL " == *" docker "* ]]; then
    [[ -z $SETUP || $SETUP == docker_stack ]] || die "--install docker needs --setup docker_stack (or no --setup)"
    SETUP=docker_stack CLI_INSTALL=$(tr ' ' '\n' <<< "$CLI_INSTALL" | grep -vx docker | xargs || true)
    [[ -n $CLI_INSTALL$CLI_REMOVE ]] || CLI_INSTALL=nginx
  fi
  if [[ " $CLI_INSTALL " == *" lemp "* ]]; then
    [[ $SETUP != docker_stack ]] || die "--install lemp is native; the Docker stack has its own nginx, PHP and Redis"
    SETUP=native_lemp CLI_INSTALL="$(tr ' ' '\n' <<< "$CLI_INSTALL" | grep -vx lemp | xargs || true) nginx php redis"
    [[ " $CLI_INSTALL " == *" mysql "* ]] || CLI_INSTALL+=" mariadb"
  fi
  if interactive && [[ -z $SETUP$CLI_INSTALL$CLI_REMOVE ]]; then
    fw_probe
    pick_server_universal
    if ((SERVER_UNIVERSAL == 2)); then ui_screen_off; cmd_firewall_on_target; return; fi
  fi
  # with -y and no --setup: the setup the server runs now
  [[ -n $SETUP || -z $TARGET_MARKER ]] || interactive || SETUP=$TARGET_MARKER
  pick_setup
  check_stack_switch
  pick_stack_parts
  plan_stack_change
  check_stack_removals
  pick_stack_config
  pick_clickhouse_password
  pick_redis_password server
  show_server_summary
  ENVIRONMENT=local CONFIRM_TITLE="Ready to change the server" CONFIRM_QUESTION="Start?" confirm_run
  ui_screen_off
  SNAPSHOT_LABEL="stack change" run_stack_change "server change"
  if ((SERVER_WANT_FIREWALL)); then
    exec {LOCK_FD}>&-   # cmd_firewall takes the target lock again
    info "Now the CSF firewall."
    cmd_firewall_on_target
  fi
}

# target_root CMD: run a shell command as root on the target (for reading the snapshots)
target_root() {
  if [[ $TARGET_CONN == local ]]; then
    if [[ $(id -u) -eq 0 ]]; then bash -c "$1"; else sudo -n bash -c "$1"; fi
  else
    timeout 30 ssh -p "$TARGET_PORT" -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new \
      "$TARGET_USER@$TARGET_HOST" "sudo -n bash -c $(printf '%q' "$1")"
  fi
}

# deploy.sh rollback: return the target to a snapshot taken before an earlier change. The parts that
# ran then run again (their kept data folders are used again), the parts added since are stopped, a
# swapped database is swapped back (its kept data folder, or the snapshot's dumps), and the setup is
# switched back when the server has no sites.
cmd_rollback() {
  need_cmds jq python3 flock tar
  ensure_state_files
  umask 077; TMP_DIR=$(mktemp -d)
  UI_ASK_WHERE="Roll back which machine?"
  pick_target; probe_target
  local snaps id snap args=() s
  snaps=$(target_root 'for f in /var/lib/deployer/snapshots/*/state.json; do [ -f "$f" ] && cat "$f"; done' | jq -s 'sort_by(.id) | reverse') \
    || die "Cannot read the snapshots on $TARGET_LABEL"
  [[ $(jq length <<< "$snaps") -gt 0 ]] || die "$TARGET_LABEL has no snapshots yet (deploy.sh server takes one before every change)."
  if [[ -n $CLI_SNAPSHOT ]]; then
    id=$CLI_SNAPSHOT
    [[ $(jq -r --arg i "$id" 'map(select(.id == $i)) | length' <<< "$snaps") == 1 ]] || die "--snapshot: no snapshot '$id' on $TARGET_LABEL (there are: $(jq -r 'map(.id) | join(" ")' <<< "$snaps"))"
  elif ! interactive; then
    die "deploy.sh rollback with -y needs --snapshot ID (there are: $(jq -r 'map(.id) | join(" ")' <<< "$snaps"))"
  else
    while IFS=$'\t' read -r i txt; do args+=("$i" "$txt"); done < <(jq -r '.[] | [.id, "\(.id)  before \(.label)  [\(([.parts | to_entries[] | select(.value == "on") | .key] + [.php | to_entries[] | select(.value == "on") | "php-\(.key)"]) as $on | if ($on | length) == 0 then "empty server" else "\(if (.setup // "") == "" then "" else "\(.setup): " end)\($on | join(" "))" end)]"] | @tsv' <<< "$snaps")
    ui_menu id "Return $TARGET_LABEL to the state before which change?" "${args[0]}" "${args[@]}"
  fi
  snap=$(jq -c --arg i "$id" '.[] | select(.id == $i)' <<< "$snaps")

  SETUP=$(jq -r '.setup // ""' <<< "$snap"); [[ -n $SETUP ]] || SETUP=${TARGET_MARKER:-native_lemp}
  check_stack_switch
  SERVER_PARTS=() SERVER_PHP=()
  for s in $(jq -r '.parts | to_entries[] | select(.value == "on") | .key' <<< "$snap"); do
    case $s in
      stack-mariadb) SERVER_PARTS+=(mariadb) ;;
      second-db) SERVER_PARTS+=("$(jq -r '.db.second' <<< "$snap")") ;;
      *) SERVER_PARTS+=("$s") ;;
    esac
  done
  read -ra SERVER_PHP <<< "$(jq -r '[.php | to_entries[] | select(.value == "on") | .key] | join(" ")' <<< "$snap")"
  ((${#SERVER_PHP[@]} == 0)) || SERVER_PARTS+=(php)
  [[ $SETUP != docker_stack ]] || { SERVER_PARTS=(nginx php redis "${SERVER_PARTS[@]}"); SERVER_PHP=(8.2); }
  DB_SWAP_MODE=restore RESTORE_SNAPSHOT=$id
  plan_stack_change
  [[ -n $DB_SWAP ]] || DB_SWAP_MODE=''
  # where the database that comes back gets its data (steps/stack-change.sh): its kept folder, else the dumps
  ROLLBACK_DB_SOURCE=''
  if [[ -n $DB_SWAP ]]; then
    local n=${DB_SWAP#*>}
    if target_root "test -d /var/lib/deployer/db-data/$n" >/dev/null 2>&1; then ROLLBACK_DB_SOURCE=folder
    elif [[ $(jq -r --arg k "$n" '[.dumps // {} | to_entries[] | select(.value == $k)] | length' <<< "$snap") -gt 0 ]]; then ROLLBACK_DB_SOURCE=dumps
    fi
  fi
  check_stack_removals
  show_server_summary
  ENVIRONMENT=local CONFIRM_TITLE="Ready to roll back" CONFIRM_QUESTION="Roll back to $id?" confirm_run
  ui_screen_off
  SNAPSHOT_LABEL="rollback to $id" run_stack_change rollback
}

# ---------------------------------------------------------------- CSF firewall
# deploy.sh firewall: installs and configures CSF (iptables rules) and LFD (blocks IPs after failed
# logins) on a target, or turns it off, on again, or uninstalls it. The questions start from what the
# target has now. A change is first applied in CSF's TESTING mode (its rules are cleared every 5
# minutes); when a new SSH connection still works, TESTING is switched off (fw_live).
CSF_DEFAULT_TCP_IN=20,21,22,25,53,853,80,110,143,443,465,587,993,995
CSF_DEFAULT_UDP_IN=20,21,53,853,80,443
CSF_DEFAULT_TCP_OUT=20,21,22,25,53,853,80,110,113,443,465,587,993,995
CSF_DEFAULT_UDP_OUT=20,21,53,853,113,123
declare -A FW=()
FW_SSH_PORTS='' FW_CLIENT_IP='' FW_SESSION_IPS='' FW_ACTION='' FW_STAY_TESTING=0 FW_SSH_OPEN=yes FW_CLOUDFLARE=no
FW_TCP_IN='' FW_UDP_IN='' FW_TCP_OUT='' FW_UDP_OUT='' FW_ALLOW='' FW_IGNORE='' FW_DENY='' FW_PING=1 FW_SSH_LIMIT=5
FW_SSH_BLOCK=1 FW_ALERT_TO=''

# fw_probe: FW[key] = the firewall state of the target (installed, testing, tcp_in, ... ssh_ports, listen)
fw_probe() {
  local out k v
  FW=()
  out=$(target_root '
    c=/etc/csf/csf.conf
    get() { sed -n "s/^$1 *= *\"\(.*\)\".*/\1/p" "$c" 2>/dev/null | tail -n 1; }
    blk() { sed -n "/^# BEGIN deployer/,/^# END deployer/p" "$1" 2>/dev/null | grep -v "^#" | sed "s/ *#.*//" | paste -sd" " -; }
    echo "installed=$([ -x /usr/sbin/csf ] && echo yes || echo no)"
    echo "version=$(/usr/sbin/csf -v 2>/dev/null | sed "s/\x1b\[[0-9;]*m//g" | grep -oE "v[0-9]+(\.[0-9]+)+" | head -n 1)"
    echo "disabled=$([ -e /etc/csf/csf.disable ] && echo yes || echo no)"
    for k in TESTING TCP_IN UDP_IN TCP_OUT UDP_OUT ICMP_IN LF_SSHD LF_SSHD_PERM LF_ALERT_TO; do echo "$k=$(get $k)"; done
    echo "allow=$(blk /etc/csf/csf.allow)"
    echo "ignore=$(blk /etc/csf/csf.ignore)"
    echo "deny=$(blk /etc/csf/csf.deny)"
    echo "ssh_ports=$(sshd -T 2>/dev/null | awk "\$1 == \"port\" {print \$2}" | sort -un | paste -sd, -)"
    echo "listen=$(ss -Hltnp 2>/dev/null | awk "{split(\$4, a, \":\"); p = a[length(a)]; n = \$6; sub(/.*\\(\\(\"/, \"\", n); sub(/\".*/, \"\", n); if (\$4 !~ /^(127\\.|\\[::1\\]|\\[::ffff:127\\.)/) print p \"(\" n \")\"}" | sort -t\( -k1,1n -u | paste -sd" " -)"
    echo "ufw=$(systemctl is-active ufw 2>/dev/null || true)"
    echo "docker=$(systemctl is-active docker 2>/dev/null || true)"
    echo "ssh_peers=$(ss -Htnp state established 2>/dev/null | awk "/sshd/ {print \$4}" | sed -E "s/:[0-9]+\$//; s/^\[//; s/\]\$//; s/^::ffff://" | sort -u | paste -sd" " -)"
    echo "nginx=$([ -x /usr/sbin/nginx ] || docker ps -q -f name=^/enzipe-nginx$ 2>/dev/null | grep -q . && echo yes || echo no)"
  ') || die "Cannot read the firewall state of $TARGET_LABEL"
  while IFS='=' read -r k v; do [[ -z $k ]] || FW[$k]=$v; done <<< "$out"
  FW_SSH_PORTS=${FW[ssh_ports]:-22}
  # the IP this machine connects from, as the target sees it (for csf.allow)
  FW_CLIENT_IP=''
  if [[ $TARGET_CONN == ssh ]]; then
    FW_CLIENT_IP=$(timeout 20 ssh -p "$TARGET_PORT" -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new \
      "$TARGET_USER@$TARGET_HOST" 'echo "${SSH_CLIENT%% *}"' 2>/dev/null) || true
  elif [[ -n ${SSH_CLIENT:-} ]]; then
    FW_CLIENT_IP=${SSH_CLIENT%% *}   # deploy.sh runs on the target, over your SSH session
  fi
  valid_ip_list "$FW_CLIENT_IP" && [[ -n $FW_CLIENT_IP ]] || FW_CLIENT_IP=''
  # every IP connected over SSH right now (this session, also through sudo or multipass shell, and
  # anyone else logged in): always allowed, so a firewall change can never cut them off
  FW_SESSION_IPS=$(join_ips "$FW_CLIENT_IP ${FW[ssh_peers]:-}")
  valid_ip_list "$FW_SESSION_IPS" || FW_SESSION_IPS=$FW_CLIENT_IP
}

check_port_list() {
  local l=${1// /} p a b ok=1
  [[ $l =~ ^[0-9]+(:[0-9]+)?(,[0-9]+(:[0-9]+)?)*$ ]] || ok=0
  if ((ok)); then
    for p in ${l//,/ }; do
      a=${p%%:*} b=${p##*:}
      ((10#$a >= 1 && 10#$b <= 65535 && 10#$a <= 10#$b)) || ok=0
    done
  fi
  ((ok)) && return 0
  echo "Enter ports from 1 to 65535 separated by commas, e.g. 22,80,443 (a range: 30000:30100)"; return 1
}
check_port_list_or_none() { [[ $1 == none ]] && return 0; check_port_list "$1" || { echo "Enter ports separated by commas (e.g. 53), or 'none'"; return 1; }; }
# PORT[/udp]:IP[,...]  e.g. 3306:1.2.3.4 8123:10.0.0.0/24 53/udp:5.6.7.8
fw_port_ip_rules() {
  local w port proto ip
  FW_PORT_RULES=()
  for w in ${1//,/ }; do
    [[ $w == none ]] && continue
    [[ $w =~ ^([0-9]+)(/(tcp|udp))?:(.+)$ ]] || return 1
    port=${BASH_REMATCH[1]} proto=${BASH_REMATCH[3]:-tcp} ip=${BASH_REMATCH[4]}
    ((port >= 1 && port <= 65535)) && valid_ip_list "$ip" || return 1
    FW_PORT_RULES+=("$proto|in|d=$port|s=$ip")
  done
}
check_port_ip() { fw_port_ip_rules "$1" && return 0; echo "Enter PORT:IP pairs separated by spaces, e.g. 3306:1.2.3.4 8123:10.0.0.0/24 53/udp:5.6.7.8, or 'none'"; return 1; }
check_ssh_limit() { [[ $1 =~ ^[0-9]+$ ]] && (($1 <= 100)) && return 0; echo "Enter a number (0 = off, CSF's default is 5)"; return 1; }
check_email_or_none() { [[ $1 == none || $1 =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]] && return 0; echo "Enter an email address, or 'none'"; return 1; }
join_ips() { tr ', ' '\n\n' <<< "$1" | grep -v -e '^$' -e '^none$' | awk '!s[$0]++' | paste -sd' ' - || true; }

# pick_firewall: FW_ACTION and the settings (CLI flags, else asked; defaults from the target)
pick_firewall() {
  local a=${CLI_FW_ACTION:-} ports def ssh_note listen_note
  if [[ ${FW[installed]} == yes ]]; then
    if [[ -z $a ]]; then
      if interactive; then
        local st="installed (${FW[version]:-?}), $([[ ${FW[disabled]} == yes ]] && echo "turned off" || { [[ ${FW[TESTING]} == 1 ]] && echo "in TESTING mode" || echo "on"; })"
        ui_menu a "CSF on $TARGET_LABEL: $st"$'\n\n'"What should happen?" setup \
          setup     "Change the settings (ports, allowed and blocked IPs, LFD)" \
          off       "Turn CSF and LFD off (csf -x; the settings stay)" \
          on        "Turn CSF and LFD on again (csf -e)" \
          uninstall "Uninstall CSF and LFD (a copy of /etc/csf is kept)"
      else a=setup; fi
    fi
  else
    [[ -z $a || $a == setup ]] || die "CSF is not installed on $TARGET_LABEL (--fw-action $a needs it)"
    a=setup
  fi
  FW_ACTION=$a
  [[ $FW_ACTION =~ ^(setup|off|on|uninstall)$ ]] || die "--fw-action: '$FW_ACTION' is not setup, off, on or uninstall"
  [[ $FW_ACTION == setup ]] || return 0

  ssh_note="SSH (port $FW_SSH_PORTS)"
  listen_note=''; [[ -z ${FW[listen]} ]] || listen_note=$'\n\n'"Listening to the network now: ${FW[listen]}"

  # 1. who may use SSH
  FW_SSH_OPEN=yes
  if [[ -n $CLI_FW_SSH ]]; then
    case $CLI_FW_SSH in open) ;; allowed) FW_SSH_OPEN=no ;; *) die "--fw-ssh: '$CLI_FW_SSH' is not open or allowed" ;; esac
  elif interactive; then
    local s; ui_menu s "Who may connect over $ssh_note?" open \
      open    "Everyone (LFD blocks an IP after failed logins)" \
      allowed "Only the allowed IPs (asked next; everyone else is blocked)"
    [[ $s == open ]] || FW_SSH_OPEN=no
  fi

  # 2. ports open to everyone
  def=web; [[ ${FW[nginx]} == yes ]] || def=ssh
  if [[ ${FW[installed]} == yes && -n ${FW[TCP_IN]} ]]; then
    local cur; cur=$(tr ',' '\n' <<< "${FW[TCP_IN]}" | grep -vxF -f <(tr ',' '\n' <<< "$FW_SSH_PORTS") | paste -sd, - || true)
    case $cur in '') def=ssh ;; 80,443|443,80) def=web ;; *) def=custom ;; esac
    [[ $cur != '' || ${FW[allow]} != *"d=443|s="* ]] || def=cloudflare
  fi
  ports=${CLI_FW_PORTS:-}
  if [[ -z $ports ]]; then
    if interactive; then
      ui_menu ports "Which ports should be open to everyone?$listen_note"$'\n\n'"(The allowed IPs always reach every port.)" "$def" \
        ssh        "Close all ports except $ssh_note" \
        web        "$ssh_note + web (80, 443)" \
        cloudflare "$ssh_note; web (80, 443) only from Cloudflare's IP ranges" \
        default    "CSF's default list (SSH, web, mail, FTP, DNS: $CSF_DEFAULT_TCP_IN)" \
        custom     "Enter the ports yourself"
    else ports=$def; [[ $def != custom ]] || ports=${FW[TCP_IN]}; fi
  fi
  FW_CLOUDFLARE=no FW_UDP_IN=''
  case $ports in
    ssh)        FW_TCP_IN='' ;;
    web)        FW_TCP_IN=80,443 ;;
    cloudflare) FW_TCP_IN='' FW_CLOUDFLARE=yes ;;
    default)    FW_TCP_IN=$CSF_DEFAULT_TCP_IN FW_UDP_IN=$CSF_DEFAULT_UDP_IN ;;
    custom)
      ui_input FW_TCP_IN "TCP ports open to everyone (comma separated; SSH is added)" "${FW[TCP_IN]:-80,443}" check_port_list \
        "Listening now: ${FW[listen]:-nothing}"
      ui_input FW_UDP_IN "UDP ports open to everyone (comma separated, or none)" "${FW[UDP_IN]:-none}" check_port_list_or_none
      [[ $FW_UDP_IN != none ]] || FW_UDP_IN='' ;;
    *) check_port_list "$ports" >/dev/null || die "--fw-ports: '$ports' is not ssh, web, cloudflare, default or a port list like 22,80,443"
       FW_TCP_IN=${ports// /} ;;
  esac
  [[ -z $CLI_FW_UDP ]] || { [[ $CLI_FW_UDP == none ]] && FW_UDP_IN='' || { check_port_list "$CLI_FW_UDP" >/dev/null || die "--fw-udp: bad port list"; FW_UDP_IN=$CLI_FW_UDP; }; }
  FW_TCP_IN=${FW_TCP_IN// /} FW_UDP_IN=${FW_UDP_IN// /}

  # 3. always allowed (csf.allow), never blocked by LFD (csf.ignore), always blocked (csf.deny)
  local def_allow; def_allow=$(join_ips "${FW[allow]//|/ } $FW_SESSION_IPS")
  def_allow=$(tr ' ' '\n' <<< "$def_allow" | grep -v -e '=' -e '^tcp$' -e '^udp$' -e '^in$' | paste -sd' ' - || true)
  if [[ -n $CLI_FW_ALLOW ]]; then FW_ALLOW=$(join_ips "$CLI_FW_ALLOW"); valid_ip_list "$FW_ALLOW" || die "--fw-allow: bad IP list"
  elif interactive; then
    ask_ip_list FW_ALLOW "IPs that always get in, every port (csf.allow), or none" "$def_allow" 1 \
      "${FW_SESSION_IPS:+Connected over SSH now: $FW_SESSION_IPS. These are always added, so the firewall never cuts you off.
}Add your office or home IP too.$([[ $FW_SSH_OPEN == no ]] && printf '\nSSH is open to these IPs only.' || true)"
  else FW_ALLOW=$def_allow; fi
  # the IPs connected over SSH now are always allowed (never locked out)
  local ip
  for ip in $FW_SESSION_IPS; do
    [[ " $FW_ALLOW " == *" $ip "* ]] || { FW_ALLOW=$(join_ips "$FW_ALLOW $ip"); warn "$ip is connected over SSH now: added to the allowed IPs"; }
  done
  if [[ $FW_SSH_OPEN == no ]]; then
    [[ -n $FW_ALLOW ]] || die "SSH only from the allowed IPs, but no IP is allowed: that would lock everyone out."
  fi
  if [[ -n $CLI_FW_IGNORE ]]; then FW_IGNORE=$(join_ips "$CLI_FW_IGNORE"); valid_ip_list "$FW_IGNORE" || die "--fw-ignore: bad IP list"
  elif interactive; then
    ask_ip_list FW_IGNORE "IPs that LFD never blocks (csf.ignore), or none" "$(join_ips "${FW[ignore]:-$FW_ALLOW}")" 1 \
      "LFD blocks IPs after failed logins. IPs in this list are never blocked (e.g. your office, monitoring)."
  else FW_IGNORE=$(join_ips "${FW[ignore]:-$FW_ALLOW}"); fi
  if [[ -n $CLI_FW_DENY ]]; then FW_DENY=$(join_ips "$CLI_FW_DENY"); valid_ip_list "$FW_DENY" || die "--fw-deny: bad IP list"
  elif interactive; then
    ask_ip_list FW_DENY "IPs that are always blocked (csf.deny), or none" "$(join_ips "${FW[deny]}")" 1
  else FW_DENY=$(join_ips "${FW[deny]}"); fi
  for ip in $FW_DENY; do
    [[ " $FW_ALLOW " != *" $ip "* ]] || die "$ip is both allowed and blocked"
    [[ " $FW_SESSION_IPS " != *" $ip "* ]] || die "$ip is connected over SSH now; it cannot be blocked"
  done

  # 4. a port only for some IPs (e.g. a database for one app server)
  local def_rules; def_rules=$(tr ' ' '\n' <<< "${FW[allow]}" | sed -n 's/^\(tcp\|udp\)|in|d=\([0-9]*\)|s=\(.*\)$/\2\/\1:\3/p' | sed 's#/tcp:#:#' \
     | grep -vE '^(80|443):' | grep -vE "^($(tr ',' '|' <<< "$FW_SSH_PORTS")):" | paste -sd' ' - || true)
  local pr=${CLI_FW_PORT_IP:-}
  if [[ -z $pr ]]; then
    if interactive; then
      ui_input pr "Ports open only to some IPs (PORT:IP, e.g. 3306:1.2.3.4 53/udp:5.6.7.8), or none" "${def_rules:-none}" check_port_ip \
        "Database and cache ports (3306, 6379, 8123, 9000) should never be open to everyone. Open them to one IP here."
    else pr=${def_rules:-none}; fi
  fi
  fw_port_ip_rules "$pr" || die "--fw-port-ip: '$pr' is not PORT:IP pairs (e.g. 3306:1.2.3.4)"

  # 5. outgoing
  local out=${CLI_FW_OUT:-}
  if [[ -z $out ]]; then
    out=all; [[ ${FW[installed]} != yes || -z ${FW[TCP_OUT]} || ${FW[TCP_OUT]} == 1:65535 ]] || out=default
    if interactive; then
      ui_menu out "Outgoing connections from the server:" "$out" \
        all     "Allow all (recommended: remote databases, APIs, mail, git work without changes)" \
        default "Only common ports (web, mail, DNS, SSH, FTP) + the sites' database ports"
    fi
  fi
  case $out in
    all)     FW_TCP_OUT=1:65535 FW_UDP_OUT=1:65535 ;;
    default) FW_TCP_OUT=$CSF_DEFAULT_TCP_OUT FW_UDP_OUT=$CSF_DEFAULT_UDP_OUT
             local p; for p in 3306 $(jq -r '.sites[] | .db.port // empty' "$SITES_JSON" 2>/dev/null | sort -un); do
               [[ ",$FW_TCP_OUT," == *",$p,"* ]] || FW_TCP_OUT+=",$p"; done ;;
    *) die "--fw-out: '$out' is not all or default" ;;
  esac

  # 6. ping, LFD
  FW_PING=${FW[ICMP_IN]:-1}
  if [[ -n $CLI_FW_PING ]]; then case $CLI_FW_PING in yes) FW_PING=1 ;; no) FW_PING=0 ;; *) die "--fw-ping: yes or no" ;; esac
  elif interactive; then
    if ui_yesno "Answer ping (ICMP echo)? Monitoring tools often use it." "$([[ $FW_PING == 1 ]] && echo yes || echo no)"; then FW_PING=1; else FW_PING=0; fi
  fi
  FW_SSH_LIMIT=${CLI_FW_SSH_LIMIT:-${FW[LF_SSHD]:-5}}
  check_ssh_limit "$FW_SSH_LIMIT" >/dev/null || die "--fw-ssh-limit: a number from 0 to 100"
  [[ -n $CLI_FW_SSH_LIMIT ]] || ! interactive || ui_input FW_SSH_LIMIT "Failed SSH logins before LFD blocks the IP (0 = off)" "$FW_SSH_LIMIT" check_ssh_limit
  FW_SSH_BLOCK=${FW[LF_SSHD_PERM]:-1}
  if [[ -n $CLI_FW_SSH_BLOCK ]]; then
    case $CLI_FW_SSH_BLOCK in perm) FW_SSH_BLOCK=1 ;; *) [[ $CLI_FW_SSH_BLOCK =~ ^[0-9]+$ ]] && ((CLI_FW_SSH_BLOCK > 1)) || die "--fw-ssh-block: perm or seconds"; FW_SSH_BLOCK=$CLI_FW_SSH_BLOCK ;; esac
  elif interactive && ((FW_SSH_LIMIT > 0)); then
    local b; ui_menu b "How long does LFD block an IP after $FW_SSH_LIMIT failed SSH logins?" "$([[ $FW_SSH_BLOCK == 1 ]] && echo perm || echo "$FW_SSH_BLOCK")" \
      3600 "1 hour" 86400 "1 day" perm "For good (until you remove it: csf -dr IP)"
    [[ $b == perm ]] && FW_SSH_BLOCK=1 || FW_SSH_BLOCK=$b
  fi
  FW_ALERT_TO=${CLI_FW_EMAIL:-${FW[LF_ALERT_TO]:-}}
  if [[ -z $CLI_FW_EMAIL ]] && interactive; then
    ui_input FW_ALERT_TO "Email for LFD's alerts (blocked IPs, logins), or none (root's mail on the server)" "${FW_ALERT_TO:-none}" check_email_or_none
  fi
  [[ $FW_ALERT_TO != none ]] || FW_ALERT_TO=''
  check_email_or_none "${FW_ALERT_TO:-none}" >/dev/null || die "--fw-email: not an email address"

  # 7. TESTING mode
  FW_STAY_TESTING=0
  if [[ -n $CLI_FW_TESTING ]]; then case $CLI_FW_TESTING in yes) FW_STAY_TESTING=1 ;; no) ;; *) die "--fw-testing: yes or no" ;; esac
  elif interactive; then
    local t; ui_menu t "Start the firewall how?" live \
      live    "Test first: TESTING mode, check a new SSH connection, then switch it on for good (recommended)" \
      testing "Stay in TESTING mode (rules cleared every 5 minutes, LFD off) until you run this again"
    [[ $t == live ]] || FW_STAY_TESTING=1
  fi
}

show_firewall_summary() {
  local dry=no tcp
  ((DRY_RUN)) && dry=yes
  tcp=$FW_TCP_IN
  [[ $FW_SSH_OPEN == no ]] || tcp=$(tr ',' '\n' <<< "$FW_SSH_PORTS,$FW_TCP_IN" | grep . | awk '!s[$0]++' | paste -sd, -)
  SUMMARY_TEXT=$({
    printf 'CSF firewall\n\n'
    printf '  Target      : %s\n' "$TARGET_LABEL"
    case $FW_ACTION in
      off)       printf '  Action      : turn CSF and LFD off (csf -x); every port is open again\n' ;;
      on)        printf '  Action      : turn CSF and LFD on again (csf -e)\n' ;;
      uninstall) printf '  Action      : uninstall CSF and LFD (a copy of /etc/csf is kept)\n' ;;
      setup)
        [[ ${FW[installed]} == yes ]] && printf '  Action      : change the settings\n' || printf '  Action      : install CSF (download.configserver.com, else download.configserver.dev)\n'
        printf '  SSH         : port %s, %s\n' "$FW_SSH_PORTS" "$([[ $FW_SSH_OPEN == no ]] && echo "only from the allowed IPs" || echo "open to everyone")"
        printf '  Open TCP    : %s\n' "${tcp:-none}"
        printf '  Open UDP    : %s\n' "${FW_UDP_IN:-none}"
        [[ $FW_CLOUDFLARE != yes ]] || printf '  Cloudflare  : 80 and 443 only from Cloudflare'"'"'s IP ranges\n'
        printf '  Allowed     : %s\n' "${FW_ALLOW:-none}"
        printf '  LFD ignores : %s\n' "${FW_IGNORE:-none}"
        printf '  Blocked     : %s\n' "${FW_DENY:-none}"
        ((${#FW_PORT_RULES[@]} == 0)) || printf '  Port rules  : %s\n' "$(printf '%s ' "${FW_PORT_RULES[@]}" | sed 's/|in|d=/ port /g; s/|s=/ from /g')"
        printf '  Outgoing    : %s\n' "$([[ $FW_TCP_OUT == 1:65535 ]] && echo all || echo "TCP $FW_TCP_OUT; UDP $FW_UDP_OUT")"
        printf '  Ping        : %s\n' "$([[ $FW_PING == 1 ]] && echo answered || echo blocked)"
        if ((FW_SSH_LIMIT)); then printf '  LFD         : block an IP after %s failed SSH logins, %s\n' "$FW_SSH_LIMIT" "$(case $FW_SSH_BLOCK in 1) echo "for good" ;; 3600) echo "for 1 hour" ;; 86400) echo "for 1 day" ;; *) echo "for ${FW_SSH_BLOCK}s" ;; esac)"
        else printf '  LFD         : SSH login blocking off\n'; fi
        printf '  Alerts      : %s\n' "${FW_ALERT_TO:-root on the server}"
        [[ ${FW[ufw]} != active ]] || printf '  ufw         : turned off (CSF replaces it)\n'
        [[ ${FW[docker]} != active ]] || printf '  Docker      : restarted after each csf reload (live-restore keeps containers up)\n'
        if ((FW_STAY_TESTING)); then printf '  Mode        : TESTING (rules cleared every 5 minutes, LFD off)\n'
        elif [[ $TARGET_CONN == ssh ]]; then printf '  Mode        : TESTING first; on for good once a new SSH connection works\n'
        else printf '  Mode        : TESTING first; on for good once you confirm that a new SSH session connects\n'; fi ;;
    esac
    printf '  Dry run     : %s\n' "$dry"
  })
  printf '\n%s\n\n' "$SUMMARY_TEXT" >&2
}

build_firewall_vars() {
  local bundle=$TMP_DIR/bundle
  rm -rf "$bundle"; mkdir -p "$bundle/files"
  VARS_FILE=$bundle/vars.sh
  q() { printf '%s=%q\n' "$1" "$2"; }
  qa() { local n=$1; shift; printf '%s=(' "$n"; (($# == 0)) || printf '%q ' "$@"; printf ')\n'; }
  {
    echo "# vars for deploy.sh firewall, written by deploy.sh $(date '+%F %T'). Removed after the run."
    q firewall_only yes
    q fw_action "$FW_ACTION"
    q fw_tcp_in "${FW_TCP_IN:-}"; q fw_udp_in "${FW_UDP_IN:-}"
    q fw_tcp_out "${FW_TCP_OUT:-1:65535}"; q fw_udp_out "${FW_UDP_OUT:-1:65535}"
    q fw_ssh_open "${FW_SSH_OPEN:-yes}"; q fw_cloudflare "${FW_CLOUDFLARE:-no}"
    # shellcheck disable=SC2086
    qa fw_allow ${FW_ALLOW:-}
    # shellcheck disable=SC2086
    qa fw_ignore ${FW_IGNORE:-}
    # shellcheck disable=SC2086
    qa fw_deny ${FW_DENY:-}
    qa fw_port_rules "${FW_PORT_RULES[@]}"
    q fw_ping "${FW_PING:-1}"; q fw_ssh_limit "${FW_SSH_LIMIT:-5}"; q fw_ssh_block "${FW_SSH_BLOCK:-1}"
    q fw_alert_to "${FW_ALERT_TO:-}"
    q fw_testing 1      # always TESTING first; fw_live switches it off
    q setup_type "${TARGET_MARKER:-native_lemp}"
    q site_domain ''; qa site_aliases; q linux_user ''; q site_id ''; q site_user_mode ''
    q DRY_RUN "$DRY_RUN"
    q VERBOSE "$VERBOSE"
    q SHOW_TIMINGS "$SHOW_TIMINGS"
    q ENGINE_COLOR "$( [[ -t 1 ]] && echo 1 || echo 0)"
  } > "$VARS_FILE"
  chmod 0600 "$VARS_FILE"
}

# fw_ssh_ok: a NEW ssh connection to the target works (not the shared one deploy.sh keeps open)
fw_ssh_ok() {
  timeout 30 ssh -p "$TARGET_PORT" -o BatchMode=yes -o ControlMaster=no -o ControlPath=none -o ConnectTimeout=12 \
    -o StrictHostKeyChecking=accept-new "$TARGET_USER@$TARGET_HOST" true >/dev/null 2>&1
}
# fw_live: the change runs in TESTING mode; switch TESTING off when a new SSH connection still works
fw_live() {
  if [[ $TARGET_CONN == local ]]; then
    # deploy.sh runs on the server: it cannot open a new SSH connection from outside, so you do
    local ans=''
    if [[ -t 0 ]] && ! ((ASSUME_YES)); then
      printf '\n%s\n%s' "CSF runs in TESTING mode now. Keep this session open and connect to this server in a NEW terminal (ssh, or multipass shell)." \
        "Type yes when the new session connected (no answer within 4 minutes keeps TESTING mode): " >&2
      read -r -t 240 ans || ans=''
    elif [[ $CLI_FW_TESTING == no ]]; then
      ans=yes   # -y --fw-testing no: switched on without the check, as asked
    fi
    if [[ ! $ans =~ ^[Yy]([Ee][Ss])?$ ]]; then
      warn "CSF stays in TESTING mode: it clears its rules within 5 minutes. When a new SSH session connects, run deploy.sh firewall again to switch it on for good."
      return 1
    fi
  elif [[ $TARGET_CONN == ssh ]]; then
    info "Checking that a new SSH connection to $TARGET_HOST:$TARGET_PORT works through the firewall..."
    sleep 2
    if ! fw_ssh_ok; then
      warn "A new SSH connection to $TARGET_HOST:$TARGET_PORT failed. CSF stays in TESTING mode: it clears its rules within 5 minutes, then you can connect again. Check the SSH port and the allowed IPs, then run deploy.sh firewall again."
      return 1
    fi
  fi
  target_root 'sed -i "s/^TESTING *=.*/TESTING = \"0\"/" /etc/csf/csf.conf && /usr/sbin/csf -r >/dev/null 2>&1 && systemctl enable --quiet lfd && systemctl restart lfd && { ! systemctl is-enabled --quiet docker 2>/dev/null || systemctl is-active --quiet docker || { systemctl reset-failed docker.service docker.socket; systemctl start docker; }; }' \
    || { warn "Could not switch TESTING mode off on $TARGET_LABEL. CSF stays in TESTING mode."; return 1; }
  if [[ $TARGET_CONN == ssh ]] && ! fw_ssh_ok; then
    warn "SSH no longer connects after TESTING mode was switched off. Use the provider's console: csf -x (turns CSF off), then fix /etc/csf/csf.conf."
    return 1
  fi
  info "CSF is on for good (TESTING off) and LFD runs."
}

cmd_firewall() {
  need_cmds jq python3 flock tar
  ensure_state_files
  umask 077; TMP_DIR=$(mktemp -d)
  UI_ASK_WHERE="Firewall on which machine?"
  pick_target; probe_target
  cmd_firewall_on_target
}
# the firewall questions and run, for the target picked already (also after deploy.sh server)
cmd_firewall_on_target() {
  fw_probe
  pick_firewall
  show_firewall_summary
  ENVIRONMENT=local CONFIRM_TITLE="Ready to change the firewall" CONFIRM_QUESTION="Start?" confirm_run
  ui_screen_off
  mkdir -p "$DATA/.locks"
  exec {LOCK_FD}>"$DATA/.locks/target-$TARGET_KEY.lock"
  flock -n "$LOCK_FD" || die "Another deploy to '$TARGET_KEY' is already running"
  audit "START firewall target=$TARGET_KEY action=$FW_ACTION tcp_in=${FW_TCP_IN:-} ssh_open=${FW_SSH_OPEN:-} allow=${FW_ALLOW:-} dry_run=$DRY_RUN"
  build_firewall_vars
  local rc=0; run_engine || rc=$?
  if ((rc == 0)) && [[ $FW_ACTION == setup ]] && ! ((DRY_RUN)); then
    if ((FW_STAY_TESTING)); then info "CSF runs in TESTING mode (rules cleared every 5 minutes). Run deploy.sh firewall again to switch it on for good."
    else fw_live || rc=3; fi
  fi
  audit "END firewall target=$TARGET_KEY rc=$rc"
  ((rc == 0)) || warn "The firewall change stopped with code $rc (log: $LOG_FILE)"
  return "$rc"
}

# deploy.sh status: a read-only report of the target (lib/status.py runs there through ssh)
cmd_status() {
  need_cmds jq python3
  NEED_ROOT=0 UI_ASK_WHERE="Server status of which machine?"
  pick_target
  ui_screen_off
  local json='' rc=0 color=''
  [[ -t 1 ]] && color=--color
  info "Reading the state of $TARGET_LABEL..."
  if [[ $TARGET_CONN == local ]]; then
    if [[ $(id -u) -eq 0 ]]; then json=$(python3 - probe < "$BASE/lib/status.py") || rc=$?
    elif sudo -n true 2>/dev/null; then json=$(sudo -n python3 - probe < "$BASE/lib/status.py") || rc=$?
    else json=$(python3 - probe < "$BASE/lib/status.py") || rc=$?
    fi
  else
    json=$(timeout 90 ssh -p "$TARGET_PORT" -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new \
      "$TARGET_USER@$TARGET_HOST" 'if sudo -n true 2>/dev/null; then sudo -n python3 - probe; else python3 - probe; fi' \
      < "$BASE/lib/status.py") || rc=$?
  fi
  ((rc == 0)) && [[ $json == "{"* ]] || die "Cannot read the state of '$TARGET_LABEL' (exit code $rc)"
  python3 -I "$BASE/lib/status.py" render $color <<< "$json"
}

# deploy.sh without a command or option: ask what to do. When a task ends (done, failed or cancelled),
# "Back to the menu?" asks whether to do something else.
cmd_menu() {
  local c='' rc=0 ans=''
  while true; do
    c=''
    ui_menu c "What do you want to do?" deploy \
      deploy          "Deploy a site" \
      server          "Set up a server: build your own stack (Docker stack, LEMP, nginx, PHP, DB, Redis, ClickHouse, Node, firewall)" \
      rollback        "Roll a server back to a snapshot taken before a change" \
      firewall        "Firewall (CSF): install, close ports, allow or block IPs, turn off" \
      add-site        "Add a site, or change a site's repository or deploy key" \
      status          "Server status: setup, services, sites" \
      certs           "Certificate expiry report" \
      register-target "Register a new target machine (installs the SSH key)" \
      quit            "Quit"
    [[ -n $c && $c != quit ]] || exit 0
    ui_screen_off
    # each task runs in a subshell: its answers, temp files, locks and an error exit stay in there.
    # set -e is switched on again inside (a subshell whose status is tested would run without it).
    set +e
    (
      set -e
      MENU_TASK=1
      trap cleanup EXIT
      trap 'exit 130' INT; trap 'exit 143' TERM; trap 'exit 129' HUP
      case $c in
        deploy)          cmd_deploy ;;
        server)          cmd_server ;;
        rollback)        cmd_rollback ;;
        firewall)        cmd_firewall ;;
        add-site)        cmd_add_site "" ;;
        status)          cmd_status ;;
        certs)           cmd_certs ;;
        register-target) cmd_register_target "" ;;
      esac
    )
    rc=$?
    set -e
    ((rc != 130 && rc != 143 && rc != 129)) || exit "$rc"   # Ctrl-C, kill, dropped session: stop
    # a plain question below the output, so the result stays readable while answering
    ans=''
    printf '\n' >&2
    read -rp "Do something else? Back to the menu [y/N]: " ans || exit "$rc"
    [[ $(ui_trim "$ans") =~ ^[Yy]([Ee][Ss])?$ ]] || exit "$rc"
  done
}

main() {
  ensure_state_files
  parse_args "$@"
  ui_init
  if (($# == 0)) && interactive; then cmd_menu; return; fi
  case ${POSITIONAL[0]:-deploy} in
    deploy)          cmd_deploy ;;
    server|stack)    cmd_server ;;
    rollback)        cmd_rollback ;;
    firewall|csf)    cmd_firewall ;;
    status)          cmd_status ;;
    add-site)        cmd_add_site "${POSITIONAL[1]:-}" ;;
    validate)        cmd_validate ;;
    list-sites)      need_cmds jq; sites_list ;;
    list-setups)     cmd_list_setups ;;
    certs)           cmd_certs ;;
    register-target) cmd_register_target "${POSITIONAL[1]:-}" ;;
    help)            usage ;;
    *)               die "Unknown command: ${POSITIONAL[0]} (see --help)" ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
