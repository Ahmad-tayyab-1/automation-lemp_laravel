# engine/lib/core.sh - the task runner: what ansible-playbook did around the tasks.
#
#   section "Checks"           a heading, like an Ansible play/role name
#   task "Do something" [secret]
#                              starts a task. Its commands' output goes to a log file, not the screen;
#                              the result (ok / changed / skipped) and time are printed when the next
#                              task starts. "secret" = never show its output (Ansible's no_log).
#   changed                    marks the current task as changed
#   skip "reason"              marks it as skipped (the code itself decides what not to run)
#   note "text"                a message shown under the task (Ansible's debug)
#   fail "text"                stops the deploy with this message
#   dry                        true in a dry run (deploy.sh --check, Ansible's check mode)
#
# A command that fails (set -e) stops the deploy too: the task, the command, and the last lines of
# its output are shown. Every changing command in the steps sits behind "dry" or a file helper below.

set -Eeuo pipefail
shopt -s nullglob

T_OK=0 T_CHANGED=0 T_SKIPPED=0
TASK_NAME='' TASK_T0='' TASK_CHANGED=0 TASK_SKIPPED='' TASK_SECRET=0 SECTION=''
TASK_NOTES=() TIMINGS=() ERR_CMD='' ERR_AT='' HANDLERS=()
ENGINE_T0=$EPOCHREALTIME
ENGINE_TMP=$(mktemp -d /tmp/deployer-engine.XXXXXX)
TASK_LOG=$ENGINE_TMP/task.log
FAIL_FILE=$ENGINE_TMP/fail.msg
: > "$TASK_LOG"

if [[ ${ENGINE_COLOR:-0} == 1 ]]; then
  C_RED=$'\033[31m' C_YEL=$'\033[33m' C_GRN=$'\033[32m' C_CYN=$'\033[36m' C_DIM=$'\033[2m' C_B=$'\033[1m' C_OFF=$'\033[0m'
else
  C_RED='' C_YEL='' C_GRN='' C_CYN='' C_DIM='' C_B='' C_OFF=''
fi

# fd 3 and 4 are the real stdout/stderr; while a task runs, 1 and 2 go to its log
exec 3>&1 4>&2
say() { printf '%s\n' "$*" >&3; }

dry() { [[ ${DRY_RUN:-0} == 1 ]]; }

# seconds since $1 (an $EPOCHREALTIME value), e.g. 1.23
since() { local a=${EPOCHREALTIME/[.,]/} b=${1/[.,]/}; local d=$(((a - b) / 10000)); printf '%d.%02d' $((d / 100)) $((d % 100)); }

section() {
  task_end
  SECTION=$1
  say ""
  say "${C_B}== $1${C_OFF}"
}

task() {
  task_end
  TASK_NAME=$1 TASK_CHANGED=0 TASK_SKIPPED='' TASK_NOTES=() TASK_T0=$EPOCHREALTIME
  TASK_SECRET=0; [[ ${2:-} != secret ]] || TASK_SECRET=1
  : > "$TASK_LOG"
  printf '   %s ... ' "$TASK_NAME" >&3
  if [[ ${VERBOSE:-0} == 1 && $TASK_SECRET == 0 ]]; then
    printf '\n' >&3
    exec > >(tee -a "$TASK_LOG" | sed 's/^/      | /' >&3) 2>&1
  else
    exec >>"$TASK_LOG" 2>&1
  fi
}

changed() { TASK_CHANGED=1; }
skip() { TASK_SKIPPED=${1:-skipped}; }
note() { TASK_NOTES+=("$*"); }
fail() { printf '%s\n' "$*" > "$FAIL_FILE"; exit 2; }

task_end() {
  [[ -n $TASK_NAME ]] || return 0
  exec 1>&3 2>&4
  local dt status n
  dt=$(since "$TASK_T0")
  if [[ -n $TASK_SKIPPED ]]; then
    status="${C_CYN}skipped${C_OFF} ${C_DIM}($TASK_SKIPPED)${C_OFF}"; T_SKIPPED=$((T_SKIPPED + 1))
  elif ((TASK_CHANGED)); then
    status="${C_YEL}changed${C_OFF}"; T_CHANGED=$((T_CHANGED + 1))
  else
    status="${C_GRN}ok${C_OFF}"; T_OK=$((T_OK + 1))
  fi
  [[ ${VERBOSE:-0} == 1 && $TASK_SECRET == 0 ]] && printf '   %s ... ' "$TASK_NAME" >&3
  printf '%s %s\n' "$status" "${C_DIM}${dt}s${C_OFF}" >&3
  for n in "${TASK_NOTES[@]}"; do printf '%s\n' "$n" | sed 's/^/      /' >&3; done
  TIMINGS+=("$dt|$SECTION : $TASK_NAME")
  TASK_NAME=''
}

# notify NAME: queue a handler function to run once at the end (Ansible's notify/handlers)
notify() { [[ " ${HANDLERS[*]} " == *" $1 "* ]] || HANDLERS+=("$1"); }
run_handlers() {
  local h
  for h in "${HANDLERS[@]}"; do "$h"; done
  HANDLERS=()
}

on_err() { ERR_CMD=$BASH_COMMAND; ERR_AT="${BASH_SOURCE[1]#"$ENGINE_DIR/"}:${BASH_LINENO[0]}"; }
trap on_err ERR

engine_exit() {
  local rc=$? msg='' dt
  exec 1>&3 2>&4
  if ((rc != 0)); then
    [[ -s $FAIL_FILE ]] && msg=$(cat "$FAIL_FILE")
    if [[ -n $TASK_NAME ]]; then
      printf '%sFAILED%s %s\n' "$C_RED" "$C_OFF" "${C_DIM}$(since "$TASK_T0")s${C_OFF}" >&3
    fi
    say ""
    if [[ -n $msg ]]; then
      say "${C_RED}FAILED:${C_OFF} ${TASK_NAME:+[$TASK_NAME] }$msg"
    else
      say "${C_RED}FAILED:${C_OFF} ${TASK_NAME:+[$TASK_NAME] }command exited with code $rc${ERR_AT:+ at $ERR_AT}"
      if [[ $TASK_SECRET == 1 ]]; then
        say "  (output hidden: this step handles passwords)"
      else
        [[ -z $ERR_CMD ]] || say "  command: $ERR_CMD"
        if [[ -s $TASK_LOG ]]; then
          say "  last output:"
          tail -n 25 "$TASK_LOG" | sed 's/^/    /' >&3
        fi
      fi
    fi
    T_FAILED=1
  fi
  dt=$(since "$ENGINE_T0")
  say ""
  say "${C_B}RECAP${C_OFF}  ok=$T_OK  changed=$T_CHANGED  skipped=$T_SKIPPED  failed=${T_FAILED:-0}  time=${dt}s$( dry && echo '  (dry run: nothing was changed)')"
  if [[ -n ${ENGINE_TIMINGS:-} ]]; then
    printf '%s\n' "${TIMINGS[@]}" > "$ENGINE_TIMINGS"
  fi
  if [[ ${SHOW_TIMINGS:-0} == 1 ]]; then
    say "Slowest steps:"
    printf '%s\n' "${TIMINGS[@]}" | sort -t'|' -k1,1 -rn | head -n 10 | awk -F'|' '{printf "  %7ss  %s\n", $1, $2}' >&3
  fi
  rm -rf "$ENGINE_TMP"
  ((rc == 0)) || exit 2
}
trap engine_exit EXIT
trap 'exit 130' INT; trap 'exit 143' TERM; trap 'exit 129' HUP
