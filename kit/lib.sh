# shellcheck shell=bash
# Shared helpers for run.sh and notify.sh. Source it from the project root.

# Settings come from the environment first, then from loopkit.env in the project root, then from the defaults
# in each script. loopkit.env is plain shell (KEY=value) and is git-ignored: it may hold tokens.
LOOPKIT_VARS=(PERMS MODEL QA_MODEL REPLAN_MODEL MAX_ITER ITER_TIMEOUT MAX_TURNS VERIFY_TIMEOUT MAX_ATTEMPTS
  STALL_LIMIT MAX_REPLANS REGRESSION_EVERY SECURITY_ROUNDS SECURITY_MODEL SECURITY_TIMEOUT SECURITY_REVIEWERS
  USERTEST_ROUNDS USERTEST_MODEL USERTEST_TIMEOUT BUDGET_USD HANG_SECONDS
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

# A duration as timeout(1) takes it (90, 90s, 20m, 3h, 1d) in seconds
secs() {
  local n=${1%[smhd]}
  case $1 in *m) echo $((n * 60)) ;; *h) echo $((n * 3600)) ;; *d) echo $((n * 86400)) ;; *) echo "$n" ;; esac
}

# When a usage limit resets, from the text Claude Code printed: "usage limit reached|<epoch>", "resets 3pm
# (Europe/Madrid)", "resets Nov 7, 3:30pm", "try again in 2h 30m". Prints the epoch, or nothing if it finds none.
reset_epoch() { # $1 = text
  local t=${1,,} now e s=0 rest when tz
  now=$(date +%s)
  if [[ $t =~ limit\ reached\|([0-9]{9,11}) ]]; then echo "${BASH_REMATCH[1]}"; return; fi
  if [[ $t =~ (again|retry|resets)\ in\ ([0-9][0-9a-z\ ]*) ]]; then
    rest=${BASH_REMATCH[2]}
    while [[ $rest =~ ^\ *([0-9]+)\ *(days|day|d|hours|hour|hrs|hr|h|minutes|minute|mins|min|m|seconds|second|secs|sec|s)(\ .*)?$ ]]; do
      case ${BASH_REMATCH[2]} in
        d*) s=$((s + BASH_REMATCH[1] * 86400)) ;; h*) s=$((s + BASH_REMATCH[1] * 3600)) ;;
        m*) s=$((s + BASH_REMATCH[1] * 60)) ;; *) s=$((s + BASH_REMATCH[1])) ;;
      esac
      rest=${BASH_REMATCH[3]}
    done
    (( s > 0 )) && echo $((now + s))
    return
  fi
  if [[ $t =~ resets\ (at\ )?(([a-z]{3,9}\ [0-9]{1,2},?\ (at\ )?)?[0-9]{1,2}(:[0-9]{2})?\ ?(am|pm)?)(\ \(([a-z0-9_/+-]+)\))? ]]; then
    when=${BASH_REMATCH[2]//,/}; when=${when// at / }
    tz=${BASH_REMATCH[8]}
    [[ -n $tz ]] && tz=$(sed -E 's#(^|/|_)([a-z])#\1\u\2#g' <<<"$tz")   # europe/madrid -> Europe/Madrid
    if [[ -n $tz ]]; then e=$(TZ=$tz date -d "$when" +%s 2>/dev/null) || return 0
    else e=$(date -d "$when" +%s 2>/dev/null) || return 0; fi
    [[ -z ${BASH_REMATCH[3]} ]] && (( e <= now )) && e=$((e + 86400))   # a bare hour that has passed: tomorrow
    echo "$e"
  fi
}
