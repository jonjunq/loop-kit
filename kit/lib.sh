# shellcheck shell=bash
# Shared helpers for run.sh and notify.sh. Source it from the project root.

# Settings come from the environment first, then from loopkit.env in the project root, then from the defaults
# in each script. loopkit.env is plain shell (KEY=value) and is git-ignored: it may hold tokens.
LOOPKIT_VARS=(PERMS MODEL QA_MODEL REPLAN_MODEL MAX_ITER ITER_TIMEOUT MAX_TURNS VERIFY_TIMEOUT MAX_ATTEMPTS
  STALL_LIMIT MAX_REPLANS REGRESSION_EVERY USERTEST_ROUNDS USERTEST_MODEL USERTEST_TIMEOUT BUDGET_USD
  NOTIFY_CMD NTFY_TOPIC NTFY_SERVER CLAUDE_BIN)

load_config() {
  local v saved
  for v in "${LOOPKIT_VARS[@]}"; do [[ -n "${!v+x}" ]] && printf -v "_lk_env_$v" '%s' "${!v}"; done
  if [[ -f loopkit.env ]]; then
    set +u
    # shellcheck source=/dev/null
    source ./loopkit.env
    set -u
  fi
  for v in "${LOOPKIT_VARS[@]}"; do
    saved="_lk_env_$v"
    [[ -n "${!saved+x}" ]] && printf -v "$v" '%s' "${!saved}"
  done
  return 0
}

# Every notification lands in logs/notify.log (another machine can collect it from there) and, if configured,
# goes to ntfy (NTFY_TOPIC) and/or to your own command (NOTIFY_CMD: a script that gets the message as its argument,
# or an inline command that uses "$1").
notify() {
  local msg="$*"
  mkdir -p logs
  echo "[$(date '+%F %T')] $msg" >> logs/notify.log
  if [[ -n "${NTFY_TOPIC:-}" ]]; then
    curl -s -m 10 -d "$msg" "${NTFY_SERVER:-https://ntfy.sh}/$NTFY_TOPIC" >/dev/null 2>&1
  fi
  if [[ -n "${NOTIFY_CMD:-}" ]]; then
    local cmd=$NOTIFY_CMD
    # shellcheck disable=SC2016  # $1 is expanded by the inner bash
    [[ "$cmd" == *'$1'* ]] || cmd+=' "$1"'   # a script path gets the message appended; an inline command uses $1
    timeout 30 bash -c "$cmd" notify "$msg" >/dev/null 2>&1
  fi
  return 0
}
