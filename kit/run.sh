#!/usr/bin/env bash
# loop-kit harness. It picks the feature, runs its verify command and keeps the score.
# Agents implement (worker), audit (QA) and replan (replanner), but never mark anything as done.
# Usage, from the project root inside tmux:  ./loopkit/run.sh
# With the usage guard running with AUTO_RESUME=1 nobody needs to start it by hand: the guard starts it whenever there
# is work (pending features, or new commits since the last DONE).
# Stop and stay stopped: touch STOP (the current iteration ends; STOP stays). Resume: rm STOP.
# Pause for manual changes without relaunching: touch PAUSE (the current iteration ends, logs/paused appears and it
# waits); rm PAUSE and the harness restarts itself (re-reading run.sh, prompts and features.json). See prompts/CHANGE.md.
# Markers for the guard: logs/done (HEAD at the last DONE), logs/halted (stopped, needs a human) and logs/waiting
# (waiting out a usage limit until the time inside, then it resumes the interrupted session by itself).
set -uo pipefail

KIT=$(dirname "$(readlink -f "$0")")   # <project>/loopkit
SELF="$KIT/run.sh"
cd "$KIT/.." || exit 1
# shellcheck source=lib.sh
source "$KIT/lib.sh"
load_config

# ---------- Settings (environment > loopkit.env > these defaults; see docs/configuration.md) ----------
PERMS="${PERMS:---permission-mode auto}"        # isolated VM/container only: PERMS="--dangerously-skip-permissions"
MODEL="${MODEL:-}"                               # empty = Claude Code's default model; e.g. MODEL=opus
QA_MODEL="${QA_MODEL:-${EVAL_MODEL:-$MODEL}}"    # model of the QA auditor
REPLAN_MODEL="${REPLAN_MODEL:-$MODEL}"           # model of the replanner
MAX_ITER="${MAX_ITER:-10000}"                    # total iterations cap
ITER_TIMEOUT="${ITER_TIMEOUT:-3h}"               # cap per agent session
MAX_TURNS="${MAX_TURNS:-300}"                    # turns cap per agent session
VERIFY_TIMEOUT="${VERIFY_TIMEOUT:-20m}"          # cap per verify command
MAX_ATTEMPTS="${MAX_ATTEMPTS:-3}"                # failed attempts per feature before replanning
STALL_LIMIT="${STALL_LIMIT:-6}"                  # iterations without progress before replanning
MAX_REPLANS="${MAX_REPLANS:-5}"                  # replans in a row without progress before stopping for a human
REGRESSION_EVERY="${REGRESSION_EVERY:-10}"       # every N new passing features, re-run every verify (0 = never)
SECURITY_ROUNDS="${SECURITY_ROUNDS:-1}"          # security-review rounds when the work runs out, before the user test (0 = never)
SECURITY_MODEL="${SECURITY_MODEL:-$QA_MODEL}"    # model of the security reviewers and their triage
SECURITY_TIMEOUT="${SECURITY_TIMEOUT:-90m}"      # cap per security reviewer
SECURITY_REVIEWERS="${SECURITY_REVIEWERS:-2}"    # reviewers in parallel: 1 = one session covers everything, 2 = back end / front end and ops
USERTEST_ROUNDS="${USERTEST_ROUNDS:-2}"          # user-test rounds when the work runs out (0 = never; needs usertest.env)
USERTEST_MODEL="${USERTEST_MODEL:-$QA_MODEL}"    # model of the testers and the triage
USERTEST_TIMEOUT="${USERTEST_TIMEOUT:-90m}"      # cap per tester
BUDGET_USD="${BUDGET_USD:-}"                     # stop when the agents' reported cost reaches this (empty = no cap)
HANG_SECONDS="${HANG_SECONDS:-$(( $(secs "$VERIFY_TIMEOUT") + 600 ))}"  # kill a session whose transcript stops growing this long (0 = never)
CLAUDE_BIN="${CLAUDE_BIN:-claude}"
LIMIT_MARGIN="${LIMIT_MARGIN:-120}"              # seconds to wait after the announced reset of a usage limit
SLEEP="${LOOPKIT_SLEEP:-sleep}"                  # long waits go through this (the tests replace it)
LEARNINGS_MAX=80                                 # lines of LEARNINGS.md before the worker is asked to condense it
# ------------------------------------------------------------------------------------------------------

FEAT=features.json
mkdir -p logs
exec 9>logs/.lock
flock -n 9 || { echo "Another run.sh is already running in this folder"; exit 1; }
rm -f logs/paused logs/halted logs/waiting

log()      { echo "[$(date '+%F %T')] $*" | tee -a logs/loop.log; }
commit()   { git add -A >/dev/null 2>&1 && git commit --no-verify -qm "$1" >/dev/null 2>&1; true; }
progress() { echo "- $(date '+%F %T') [harness] $*" >> PROGRESS.md; }
# Waits $1 seconds in steps; returns 1 as soon as STOP or PAUSE appears
nap() {
  local left=$1
  while (( left > 0 )); do
    [[ -f STOP || -f PAUSE ]] && return 1
    $SLEEP $(( left < 30 ? left : 30 )); left=$(( left - 30 ))
  done
}
# Before every git reset --hard: if the commit did not go in, stop rather than lose work
clean_or_die() {
  [[ -z "$(git status --porcelain)" ]] && return
  log "HALTED: uncommitted changes that a reset would wipe (git identity? disk full?)"
  notify "Loop HALTED: git cannot commit. Check logs/loop.log"
  echo "git cannot commit" > logs/halted; exit 3
}
pause_if_requested() {
  [[ -f PAUSE ]] || return 0
  log "PAUSED: waiting for PAUSE to be removed"; : > logs/paused
  while [[ -f PAUSE && ! -f STOP ]]; do sleep 10; done
  rm -f logs/paused
  [[ -f STOP ]] && return 0
  log "Pause over: restarting to pick up the changes"
  exec 9>&-          # release the lock: the new process takes it again
  exec "$SELF"       # same environment (MODEL, PERMS...)
}
# What the agents have cost so far, as reported by Claude Code (on a subscription it is the API-equivalent cost)
spent_usd() {
  cat logs/iter-*.jsonl 2>/dev/null | grep -E '"type" *: *"result"' \
    | jq -rs 'map(.total_cost_usd // 0) | add // 0 | . * 100 | round / 100'
}
over_budget() {
  [[ -n "$BUDGET_USD" ]] || return 1
  awk -v s="$(spent_usd)" -v b="$BUDGET_USD" 'BEGIN { exit !(s >= b) }'
}

remaining() { jq '[.features[]|select(.passes!=true and (.blocked//false)!=true)]|length' "$FEAT"; }
passing()   { jq '[.features[]|select(.passes==true)]|length' "$FEAT"; }
field()     { jq -r --arg id "$1" ".features[]|select(.id==\$id)|$2" "$FEAT"; }
# Next feature: pending, not blocked, every dependency passing; lowest priority first
next_feature() {
  jq -r '([.features[]|select(.passes==true)|.id]) as $ok
    | [.features[]|select(.passes!=true and (.blocked//false)!=true)
       |select(all((.depends_on//[])[]; . as $d | ($ok|index($d)) != null))]
    | sort_by(.priority) | .[0].id // empty' "$FEAT"
}
set_feat() { # $1 = id, $2 = jq expression on the feature, rest = extra jq args
  local id="$1" expr="$2"; shift 2
  jq --arg id "$id" "$@" "(.features[]|select(.id==\$id)) |= ($expr)" "$FEAT" > "$FEAT.tmp" && mv "$FEAT.tmp" "$FEAT"
}
fail_feat() { # $1 = id, $2 = reason
  set_feat "$1" '.attempts=((.attempts//0)+1) | .notes=$n' --arg n "$2"
  progress "$1 FAILS (attempt $(field "$1" .attempts)): $2"
  log "$1 FAIL: $2"
}

# ---------- Agent sessions ----------
# Every session and verify runs with its own LOOPKIT_SESSION token in the environment. Whatever it starts inherits it,
# even servers that detach into their own process group, so the harness can find and kill all of it afterwards.
session_pids() { grep -lzxF "LOOPKIT_SESSION=$1" /proc/[0-9]*/environ 2>/dev/null | cut -d/ -f3; }
kill_session() { # $1 = token. Kills what is left of a session; prints how many processes it found (returns 1 if none)
  local p; p=$(session_pids "$1"); [[ -n $p ]] || return 1
  # shellcheck disable=SC2086  # one pid per word
  kill -TERM $p 2>/dev/null; sleep 2
  # shellcheck disable=SC2046
  kill -KILL $(session_pids "$1") 2>/dev/null
  wc -w <<<"$p"
}
# Kills a session whose transcript has not grown in HANG_SECONDS (a tool that never returns, a server in the foreground)
watchdog() { # $1 = pid, $2 = token, $3 = flag file to leave, rest = the session's output files
  local pid=$1 tok=$2 flag=$3 size last="" idle=0 step nap
  shift 3; step=$(( HANG_SECONDS >= 60 ? 10 : 1 ))
  trap 'kill "$nap" 2>/dev/null; exit 0' TERM
  while kill -0 "$pid" 2>/dev/null; do
    sleep "$step" & nap=$!; wait "$nap"
    size=$(stat -c %s -- "$@" 2>/dev/null | tr '\n' ' ')
    if [[ $size == "$last" ]]; then idle=$(( idle + step )); else idle=0; last=$size; fi
    if (( idle >= HANG_SECONDS )); then : > "$flag"; kill_session "$tok" >/dev/null; exit 0; fi
  done
}
# loopkit.env is git-ignored, so no reset protects it: any agent that changes it gets the copy taken at start back
restore_env() { # $1 = role
  if [[ -f logs/.loopkit.env ]]; then cmp -s loopkit.env logs/.loopkit.env && return 0; cp -p logs/.loopkit.env loopkit.env
  else [[ -e loopkit.env ]] || return 0; rm -f loopkit.env; fi
  log "$1 touched the harness -> reverted: loopkit.env" >&2
}

RESUME_PROMPT="The session was interrupted (usage limit or network) and the harness has just resumed it. Carry on with the same task from where you left off; your instructions are earlier in this conversation."
# Runs one Claude Code session, or resumes session $RESUME_SID. Prints "<status> <reset epoch|-> <session id|-> <worked>"
# status: ok | max_turns | timeout | hung | limit | transient | error; worked = assistant messages in this run
run_once() { # $1 = role, $2 = prompt file, $3 = model, $4 = extra text
  local out err off eoff margs=() rargs=() prompt tok flag pid wd="" rc n info sub iserr text sid worked reset limited
  out="logs/iter-$(printf %05d "$i")-$1.jsonl"; err="${out%.jsonl}.err"
  off=$(stat -c %s "$out" 2>/dev/null || echo 0); eoff=$(stat -c %s "$err" 2>/dev/null || echo 0)
  [[ -n "$3" ]] && margs=(--model "$3")
  if [[ -n "${RESUME_SID:-}" ]]; then rargs=(--resume "$RESUME_SID"); prompt=$RESUME_PROMPT
  else prompt="$(cat "$2")${4:+

$4}"; fi
  tok="lk-$$-$BASHPID-$RANDOM$RANDOM"; flag="logs/.hung-$tok"
  # shellcheck disable=SC2086  # PERMS holds several words on purpose
  LOOPKIT_ROLE="$1" LOOPKIT_SESSION="$tok" timeout -k 60 "$ITER_TIMEOUT" "$CLAUDE_BIN" -p "$prompt" "${rargs[@]}" \
    $PERMS --max-turns "$MAX_TURNS" "${margs[@]}" --output-format stream-json --verbose >>"$out" 2>>"$err" 9>&- &
  pid=$!
  (( HANG_SECONDS > 0 )) && { watchdog "$pid" "$tok" "$flag" "$out" "$err" & wd=$!; }
  wait "$pid"; rc=$?
  [[ -n $wd ]] && { kill "$wd" 2>/dev/null; wait "$wd" 2>/dev/null; }
  n=$(kill_session "$tok") && log "$1: killed $n processes the session left running" >&2
  restore_env "$1"
  # Only this run's part of the transcript (a retry appends to the same file)
  info=$(tail -c +$((off + 1)) "$out" | jq -Rrs '[split("\n")[] | fromjson? | objects] as $m
    | ($m | map(select(.type == "result")) | last) as $r
    | [$m[] | select(.type == "rate_limit_event" and .rate_limit_info.status == "rejected") | .rate_limit_info.resetsAt]
      + [$m[] | select(.type == "assistant" and .api_error == "usage_limit_reached") | .api_error_params.rate_limit_info.resetsAt // 0]
      | . as $lim
    | [ $r.subtype // "-", ($r.is_error // false | tostring),
        ([($r.result // empty | tostring), (($r.errors // [])[] | tostring)] | join(" ") | gsub("\\s+"; " ") | .[0:600] | if . == "" then "-" else . end),
        ([$m[] | .session_id // empty] | first // "-"),
        ([$m[] | select(.type == "assistant" and .error == null and .api_error == null)] | length | tostring),
        ($lim | map(select(. != null and . > 0)) | last // "-" | tostring),
        ($lim | length > 0 | tostring) ] | @tsv' 2>/dev/null)
  IFS=$'\t' read -r sub iserr text sid worked reset limited <<<"$info"
  : "${sub:=-}" "${sid:=-}" "${worked:=0}" "${reset:=-}" "${limited:=false}"
  if [[ -f $flag ]]; then rm -f "$flag"; echo "hung - $sid $worked"; return; fi
  (( rc == 124 || rc == 137 )) && { echo "timeout - $sid $worked"; return; }
  [[ $sub == error_max_turns ]] && { echo "max_turns - $sid $worked"; return; }
  [[ $sub == success && $iserr != true ]] && { echo "ok - $sid $worked"; return; }
  # It did not finish well: a usage limit (the structured event first, the wording as a fallback), or something else
  text="$text $(tail -c +$((eoff + 1)) "$err" | tail -c 1000 | tr '\n' ' ')"
  [[ $reset == - ]] && reset=$(reset_epoch "$text") && : "${reset:=-}"
  if [[ $limited == true ]] || grep -qiE 'usage limit|hit your limit|limit reached|limit will reset|resets [0-9a-z]' <<<"$text"; then
    echo "limit $reset $sid $worked"
  elif [[ $sub == - ]] || grep -qiE 'limit|rate|overload|429|529|quota|credit|api error|network' <<<"$text"; then
    echo "transient - $sid $worked"   # no result at all (network, login, limit before starting...) or a passing error
  else
    echo "error - $sid $worked"
  fi
}
# Same as run_once, but waits out usage limits (until the announced reset when there is one, with backoff otherwise)
# and transient failures, then resumes the interrupted session if it had started working (a new one if that fails).
# Prints run_once's status, or "stopped" when STOP or PAUSE appeared while waiting.
run_agent() {
  local st reset sid worked resume="" backoff=60 now until
  while :; do
    read -r st reset sid worked <<<"$(RESUME_SID=$resume run_once "$@")"
    if [[ -n $resume && $st != limit && ( $sid == - || ( $st == error && $worked == 0 ) ) ]]; then
      log "$1: could not resume session $resume -> new session" >&2; resume=""; continue
    fi
    [[ $st == limit || $st == transient ]] || { echo "$st"; return; }
    [[ -f STOP ]] && { echo stopped; return; }
    [[ $sid != - ]] && (( worked > 0 )) && resume=$sid   # it had started: pick it up where it stopped
    now=$(date +%s)
    if [[ $st == limit && $reset =~ ^[0-9]+$ ]] && (( reset > now && reset < now + 8 * 86400 )); then
      until=$(( reset + LIMIT_MARGIN ))
      log "$1: usage limit. Waiting until $(date -d "@$until" '+%F %H:%M') ($(( until - now ))s)${resume:+, then resuming session $resume}" >&2
      [[ "$(cat logs/waiting 2>/dev/null)" == "$until" ]] || notify "Loop waiting for the usage limit: it resumes by itself at $(date -d "@$until" '+%H:%M')"
      echo "$until" > logs/waiting   # the usage guard leaves the loop alone while it waits
      nap $(( until - now )) || { rm -f logs/waiting; echo stopped; return; }
      rm -f logs/waiting; backoff=60
    else
      log "$1: transient failure (usage limit / network). Waiting ${backoff}s${resume:+, then resuming session $resume}" >&2
      (( backoff == 3600 )) && notify "Loop waiting: usage limit or network down"
      nap "$backoff" || { echo stopped; return; }
      backoff=$(( backoff*2 > 3600 ? 3600 : backoff*2 ))
    fi
  done
}

run_verify() { # $1 = id. Exit 0 when the verify passes; whatever it leaves running is killed
  local cmd rc tok="lk-$$-$BASHPID-$RANDOM$RANDOM"; cmd=$(field "$1" .verify)
  LOOPKIT_SESSION="$tok" timeout -k 30 "$VERIFY_TIMEOUT" bash -c "$cmd" >"logs/verify-$1.log" 2>&1 9>&-
  rc=$?; kill_session "$tok" >/dev/null; return $rc
}

# After the replanner or the triage: keep only features.json and DECISIONS.md, revert the rest and validate the JSON
keep_plan() { # $1 = previous commit, $2 = previous copy of features.json, $3 = who (for the log)
  cp "$FEAT" logs/.plan-out.json; cp DECISIONS.md logs/.decisions-out.md 2>/dev/null
  git reset -q --hard "$1"; git clean -fdq
  cp logs/.plan-out.json "$FEAT"; [[ -f logs/.decisions-out.md ]] && cp logs/.decisions-out.md DECISIONS.md
  if ! jq -e --slurpfile old "$2" '
      ([.features[].id]) as $ids
      | ($ids|length) == ($ids|unique|length)                                       # unique ids
      and ([$old[0].features[].id] - $ids == [])                                    # no feature deleted
      and all(.features[]; ((.depends_on//[]) - $ids) == [])                        # dependencies exist
      and all(.features[]; .verify|type=="string" and length>0)                     # everything has a verify
      and ([.features[]|select(.passes==true)|.id] - [$old[0].features[]|select(.passes==true)|.id] == [])  # no free passes
    ' "$FEAT" >/dev/null 2>&1; then
    log "$3 left an invalid features.json -> restored"; cp "$2" "$FEAT"
  fi
}

# The replanner may only touch features.json and DECISIONS.md; everything else is reverted and the JSON validated
replan() { # $1 = reason
  local pre snap=logs/.prereplan.json stuck_before
  (( ++replans > MAX_REPLANS )) && {
    log "HALTED: $MAX_REPLANS replans in a row without progress. Needs a human."
    notify "Loop HALTED: $MAX_REPLANS replans without progress. Check logs/loop.log"
    echo "$MAX_REPLANS replans without progress" > logs/halted; exit 2; }
  log "Replan $replans/$MAX_REPLANS: $1"
  commit "harness: before replan"; clean_or_die
  cp "$FEAT" "$snap"; pre=$(git rev-parse HEAD)
  stuck_before=$(jq -r --argjson m "$MAX_ATTEMPTS" '[.features[]|select(.passes!=true and (.blocked//false)!=true and (.attempts//0)>=$m)|.id]|join(" ")' "$FEAT")
  st=$(run_agent replan "$KIT/prompts/REPLAN.md" "$REPLAN_MODEL" "REASON FOR THIS REPLAN: $1")
  keep_plan "$pre" "$snap" "Replanner ($st)"
  # A stuck feature that is still just as stuck gets blocked by the harness, so the replan does not repeat forever
  for id in $stuck_before; do
    if [[ "$(field "$id" '(.blocked//false)')" != true ]] && (( $(field "$id" '.attempts//0') >= MAX_ATTEMPTS )); then
      set_feat "$id" '.blocked=true | .notes=("[harness] blocked: the replanner did not solve it. " + (.notes//""))'
      log "$id blocked by the harness"
    fi
  done
  commit "replan: $1"; stall=0
  notify "Replanned: $1"
}

regression_sweep() {
  local id bad=()
  log "Regression sweep"
  for id in $(jq -r '.features[]|select(.passes==true)|.id' "$FEAT"); do
    [[ -f STOP ]] && return
    run_verify "$id" || { bad+=("$id"); set_feat "$id" '.passes=false | .notes=$n' --arg n "[harness] regression found in iter $i: its verify no longer passes (logs/verify-$id.log)"; }
  done
  if (( ${#bad[@]} )); then
    log "Regressions: ${bad[*]}"; progress "Regressions found: ${bad[*]}"; notify "Regressions: ${bad[*]}"
    commit "harness: regressions ${bad[*]}"
  fi
}

# ---------- Guards around the worker ----------
# The worker may not change the harness: what it changed in loopkit/, demo.env or usertest.env goes back as it was.
# (Your own changes to them go in while the loop is paused: see prompts/CHANGE.md.)
revert_harness() { # $1 = commit before the worker, $2 = id
  local f touched
  touched=$(git diff --name-only --no-renames "$1" HEAD -- loopkit demo.env usertest.env)
  [[ -n $touched ]] || return 0
  while IFS= read -r f; do
    if git cat-file -e "$1:$f" 2>/dev/null; then git checkout -q "$1" -- "$f"; else git rm -qf -- "$f"; fi
  done <<<"$touched"
  log "Worker touched the harness -> reverted: $(tr '\n' ' ' <<<"$touched")"
  commit "harness: $2 worker touched the harness -> reverted"
}

# Signs in the worker's diff that a check got weaker, for the QA to look at (a sign is not a verdict)
TEST_FILES='(^|/)(tests?|__tests__|specs?|e2e|cypress)/|[._-](test|spec)s?\.[a-z0-9]+$|(^|/)test_[^/]*\.py$'
red_flags() { # $1 = commit before the worker, $2 = id
  local from=$1 f w n tests=() lines verify cfg quotes="\"'"
  local skip='\.(skip|only)\(|\b(xit|xdescribe|xtest|fit|fdescribe)\(|@(pytest\.mark\.)?(skip|xfail)|\bpytest\.skip\(|\bt\.Skip(Now)?\(|#\[ignore\]|@(Disabled|Ignore)\b|\b(test|it)\.todo\('
  local assert='\b(expect|assert[A-Za-z_]*)\b|\bt\.(Error|Fatal|Fail)'
  local cases='^.\s*(it|test|describe)(\.each)?\(|\bdef test_|\bfunc Test|#\[test\]|@Test\b'
  f=$(git diff --name-only --diff-filter=D "$from" HEAD | grep -E "$TEST_FILES" | head -10 | tr '\n' ' ')
  [[ -n $f ]] && echo "- test files deleted: $f"
  mapfile -t tests < <(git diff --name-only "$from" HEAD | grep -E "$TEST_FILES")
  if (( ${#tests[@]} )); then
    lines=$(git diff -U0 "$from" HEAD -- "${tests[@]}" | grep -E '^[-+]' | grep -vE '^(\+\+\+|---) ')
    changed() { grep -E "^[$1]" <<<"$lines" | grep -cE "$2"; }   # $1 = + or -, $2 = regex
    (( $(changed + "$skip") > $(changed - "$skip") )) && echo "- tests disabled: $(changed + "$skip") lines with skip/only/xit/todo added, $(changed - "$skip") removed"
    (( $(changed - "$assert") > $(changed + "$assert") )) && echo "- fewer assertions in the tests: $(changed - "$assert") lines with asserts removed, $(changed + "$assert") added"
    (( $(changed - "$cases") > $(changed + "$cases") )) && echo "- fewer test cases: $(changed - "$cases") removed, $(changed + "$cases") added"
  fi
  # What the verify runs: files it names that existed before and lost lines, and the test runner's configuration
  verify=$(field "$2" .verify); f=""
  for w in $verify; do
    w=${w//[$quotes]/}
    [[ $w == */* || $w == *.* ]] && git cat-file -e "$from:$w" 2>/dev/null || continue
    (( $(git diff --numstat "$from" HEAD -- "$w" | awk '{print $2 + 0}') > 0 )) && f+="$w "
  done
  cfg=$(git diff --name-only "$from" HEAD | grep -E '(^|/)((playwright|jest|vitest|cypress|karma)\.config\.[a-z]+|pytest\.ini|tox\.ini|conftest\.py|\.mocharc[^/]*)$' | tr '\n' ' ')
  git diff -U0 "$from" HEAD -- package.json pyproject.toml | grep -qE '^[-+][^-+].*("(pre|post)?(test|e2e|verify)[^"]*" *:|\[tool\.pytest|testpaths|addopts)' \
    && cfg+="test scripts in package.json/pyproject.toml "
  [[ -n $f || -n $cfg ]] && echo "- what the verify runs was changed: ${f}${cfg}(the verify is: $verify)"
  return 0
}

# A feature's verify must fail before anyone works on it; if it passes, it checks nothing (or the work is already
# there) and the replanner decides. Only before the first worker (logs/worked lists the features that had one; the
# commits tell for older runs), once per verify (logs/precheck/<id> keeps it), and never for regression gates
# ("Full regression" features), which are meant to pass once their dependencies do.
precheck_due() { # $1 = id
  (( $(field "$1" '.attempts//0') == 0 )) || return 1
  [[ "$(field "$1" '(.description // "") | test("full regression|^\\[regression"; "i")')" == false ]] || return 1
  [[ "$(cat "logs/precheck/$1" 2>/dev/null)" != "$(field "$1" .verify)" ]] || return 1
  ! grep -qxF "$1" logs/worked 2>/dev/null || return 1
  (( $(git log --format=%s | awk -v id="$1" 'index($0, id ":") == 1 || index($0, "harness: " id " worker (") == 1 \
       || $0 == "harness: " id " PASS" || $0 == "harness: " id " fail" {n++} END {print n+0}') == 0 ))
}
already_green() { # $1 = id. Marks a feature whose verify already passes, for the replanner
  mkdir -p logs/precheck; field "$1" .verify > "logs/precheck/$1"
  set_feat "$1" '.notes=$n' --arg n "[harness] verify already passes before any work: empty/weak verify or already done (logs/verify-$1.log)"
  progress "$1: verify already passes before any work"; log "$1: verify already passes before any work"
}

# ---------- Security review ----------
# When the work runs out, before the user test: read-only reviewers look for exploitable flaws in the code (their
# changes are discarded) and a triage turns the verified ones into [Security N] features. Rounds are counted like the
# user test's: "security: round" commits since the last "change:" commit; a round with nothing to fix ends the batch.
since_batch() { git log --format=%s | awk '/^change:/{exit} {print}'; }  # commit subjects since the last change
security_pending() {
  (( SECURITY_ROUNDS > 0 )) || return 1
  (( $(since_batch | grep -c '^security: round') < SECURITY_ROUNDS )) || return 1
  local last_round; last_round=$(since_batch | grep -m1 '^security: round')  # no pipe into grep -q: see usertest_pending
  [[ $last_round != *'nothing to fix'* ]]
}
security_end() { # $1 = round, $2 = summary. Records the round even when nothing changed
  log "Security review, round $1: $2"; progress "Security review, round $1: $2"
  git add -A >/dev/null 2>&1; git commit --no-verify -q --allow-empty -m "security: round $1 · $2" >/dev/null 2>&1
}
security() {
  local n dir pre snap=logs/.presecurity.json new reports base done_ids st a name pids=() areas
  n=$(( $(since_batch | grep -c '^security: round') + 1 ))
  dir="$PWD/logs/security-$(printf %05d "$i")"; mkdir -p "$dir"
  log "Security review, round $n/$SECURITY_ROUNDS (reports in ${dir#"$PWD"/})"
  commit "harness: before security review"; clean_or_die; pre=$(git rev-parse HEAD)
  if (( SECURITY_REVIEWERS > 1 )); then
    areas=("backend|server side: authentication, sessions, account recovery, authorization on every route that takes an id, injection, file and upload handling, rate limits, real-time channels, secrets, development/test/demo-only routes and flags, and what the API reveals about other users (including through repeated or crafted requests)"
           "frontend-ops|client side and operations: XSS and unsafe rendering, tokens or personal data in browser storage or caches, security headers, dependencies, how the app is built and started for anything published (production vs development mode, demo and seed data, default credentials), logs and data at rest, and whether the privacy and retention promises in the SPEC and any privacy text are honoured")
  else
    areas=("all|the whole project: every area of a security review")
  fi
  base=$(git log --format=%H -E --grep='^(change:|security: round)' -1)
  done_ids=$(git log --format=%s ${base:+"$base"..HEAD} | sed -n 's/^harness: \(F[0-9.]*\) PASS$/\1/p' | sort -u | tr '\n' ' ')
  for a in "${areas[@]}"; do
    name=${a%%|*}; mkdir -p "$dir/$name"
    ( ITER_TIMEOUT=$SECURITY_TIMEOUT run_agent "security-$name" "$KIT/prompts/SECURITY.md" "$SECURITY_MODEL" "ROUND: $n
YOUR AREA ($name): ${a#*|}
THE OTHER REVIEWERS' AREAS: $(printf '%s; ' "${areas[@]%%|*}")
FEATURES BUILT SINCE THE LAST REVIEW OR CHANGE: ${done_ids:-all}
YOUR WORKING FOLDER: $dir/$name
YOUR REPORT: $dir/report-$name.md" >"$dir/$name/status" ) &
    pids+=($!)
  done
  wait "${pids[@]}"
  git reset -q --hard "$pre"; git clean -fdq

  reports=$(ls "$dir"/report-*.md 2>/dev/null)
  if [[ -z "$reports" ]]; then
    notify "Security review: no reviewer delivered a report (${dir#"$PWD"/})"
    security_end "$n" "nothing to fix (no reports)"; return
  fi

  # Triage: reports -> [Security N] features and an entry in DECISIONS.md
  cp "$FEAT" "$snap"
  st=$(run_agent security-triage "$KIT/prompts/SECURITY_TRIAGE.md" "$SECURITY_MODEL" "ROUND: $n of $SECURITY_ROUNDS
REPORTS:
$reports")
  keep_plan "$pre" "$snap" "Security triage ($st)"
  new=$(jq --slurpfile old "$snap" '[.features[].id] - [$old[0].features[].id] | join(" ")' -r "$FEAT")
  if [[ -n "$new" ]]; then
    security_end "$n" "fix features: $new"
    notify "Security review, round $n: new fix features $new. Details in DECISIONS.md"
  else
    security_end "$n" "nothing to fix"
    notify "Security review, round $n: nothing to fix now. Low-risk notes and decisions for you are in DECISIONS.md"
  fi
}

# ---------- User test ----------
# When the work runs out, testers with a browser use an isolated copy of the app (usertest.env) and a triage turns
# their reports into features. Rounds are counted by "usertest: round" commits since the last "change:" commit, so
# every batch of owner changes gets its own; a round that leaves nothing to fix ends the batch.
ut_pid=""
ut_stop() {
  [[ -n "$ut_pid" ]] && { pkill -P "$ut_pid" 2>/dev/null; kill "$ut_pid" 2>/dev/null; wait "$ut_pid" 2>/dev/null; }
  ut_pid=""
}
trap ut_stop EXIT
usertest_pending() {
  (( USERTEST_ROUNDS > 0 )) && [[ -f usertest.env ]] || return 1
  # No pipe ending in grep -m1/-q here: with pipefail, git log gets SIGPIPE when grep stops reading early,
  # the pipe counts as failed and the `!` turned that into the opposite answer. Compare in a variable instead.
  local last_change last_round
  last_change=$(git log --format=%s | grep -m1 '^change:')
  [[ $last_change != *'[no usertest]'* ]] || return 1  # the owner asked for a batch without user test
  (( $(since_batch | grep -c '^usertest: round') < USERTEST_ROUNDS )) || return 1
  last_round=$(since_batch | grep -m1 '^usertest: round')
  [[ $last_round != *'nothing to fix'* ]]
}
usertest_end() { # $1 = round, $2 = summary. Records the round even when nothing changed
  log "User test, round $1: $2"; progress "User test, round $1: $2"
  git add -A >/dev/null 2>&1; git commit --no-verify -q --allow-empty -m "usertest: round $1 · $2" >/dev/null 2>&1
}
usertest() {
  local n dir z name pids=() pre snap=logs/.preusertest.json new done_ids base reports up=0
  local USERTEST_PORT=3400 USERTEST_HEALTH=/ USERTEST_INFO="" USERTEST_ZONES=() USERTEST_BUILD="" USERTEST_SEED="" USERTEST_START=""
  n=$(( $(since_batch | grep -c '^usertest: round') + 1 ))
  dir="$PWD/logs/usertest-$(printf %05d "$i")"; mkdir -p "$dir/data"
  log "User test, round $n/$USERTEST_ROUNDS (reports in ${dir#"$PWD"/})"
  commit "harness: before user test"; clean_or_die; pre=$(git rev-parse HEAD)
  export USERTEST_DATA="$dir/data"
  set +u
  # shellcheck source=/dev/null
  source ./usertest.env
  set -u
  export USERTEST_PORT
  if [[ -z "$USERTEST_START" || ${#USERTEST_ZONES[@]} -eq 0 ]]; then
    notify "User test skipped: usertest.env needs USERTEST_START and USERTEST_ZONES"
    usertest_end "$n" "nothing to fix (usertest.env incomplete)"; return
  fi

  # Isolated copy: build, its own data and a server on USERTEST_PORT
  if ! timeout -k 30 "$VERIFY_TIMEOUT" bash -c "${USERTEST_BUILD:-true}" >"$dir/build.log" 2>&1 \
     || ! timeout -k 30 10m bash -c "${USERTEST_SEED:-true}" >"$dir/seed.log" 2>&1; then
    notify "User test: the copy does not build or seed (${dir#"$PWD"/})"
    usertest_end "$n" "nothing to fix (the copy does not build or seed: ${dir#"$PWD"/})"; return
  fi
  bash -c "$USERTEST_START" >"$dir/server.log" 2>&1 & ut_pid=$!
  for _ in $(seq 60); do curl -sf -o /dev/null "http://localhost:$USERTEST_PORT$USERTEST_HEALTH" && { up=1; break; }; sleep 2; done
  if (( ! up )); then
    ut_stop; notify "User test: the copy does not start (${dir#"$PWD"/}/server.log)"
    usertest_end "$n" "nothing to fix (the copy does not start)"; return
  fi

  # Testers in parallel, one per zone, told what was built since the last round or change so they check it
  base=$(git log --format=%H -E --grep='^(change:|usertest: round)' -1)
  done_ids=$(git log --format=%s ${base:+"$base"..HEAD} | sed -n 's/^harness: \(F[0-9.]*\) PASS$/\1/p' | sort -u | tr '\n' ' ')
  for z in "${USERTEST_ZONES[@]}"; do
    name=${z%%|*}; mkdir -p "$dir/$name"
    ( ITER_TIMEOUT=$USERTEST_TIMEOUT run_agent "tester-$name" "$KIT/prompts/TESTER.md" "$USERTEST_MODEL" "ROUND: $n
URL OF THE COPY: http://localhost:$USERTEST_PORT
ABOUT THE COPY: $USERTEST_INFO
YOUR ZONE ($name): ${z#*|}
THE OTHER TESTERS' ZONES: $(printf '%s; ' "${USERTEST_ZONES[@]%%|*}")
FEATURES BUILT SINCE THE LAST ROUND OR CHANGE: ${done_ids:-all}
YOUR WORKING FOLDER: $dir/$name
YOUR REPORT: $dir/report-$name.md" >"$dir/$name/status" ) &
    pids+=($!)
  done
  wait "${pids[@]}"
  git reset -q --hard "$pre"; git clean -fdq

  reports=$(ls "$dir"/report-*.md 2>/dev/null)
  if [[ -z "$reports" ]]; then
    ut_stop; notify "User test: no tester delivered a report (${dir#"$PWD"/})"
    usertest_end "$n" "nothing to fix (no reports)"; return
  fi

  # Triage: reports -> new features and an entry in DECISIONS.md (the copy is still up to reproduce things)
  cp "$FEAT" "$snap"
  st=$(run_agent triage "$KIT/prompts/TRIAGE.md" "$USERTEST_MODEL" "ROUND: $n of $USERTEST_ROUNDS
URL OF THE COPY (still running): http://localhost:$USERTEST_PORT
ABOUT THE COPY: $USERTEST_INFO
REPORTS:
$reports")
  ut_stop
  keep_plan "$pre" "$snap" "Triage ($st)"
  new=$(jq --slurpfile old "$snap" '[.features[].id] - [$old[0].features[].id] | join(" ")' -r "$FEAT")
  if [[ -n "$new" ]]; then
    usertest_end "$n" "fix features: $new"
    notify "User test, round $n: new fix features $new. Details in DECISIONS.md"
  else
    usertest_end "$n" "nothing to fix"
    notify "User test, round $n: nothing to fix now. Minor issues and product questions are in DECISIONS.md"
  fi
}

# ---------- Start ----------
[[ -f "$FEAT" ]] || { echo "No $FEAT here. Plan first: see loopkit/prompts/PLAN.md"; exit 1; }
jq -e '([.features[].id]) as $ids
  | ($ids|length) == ($ids|unique|length)
  and all(.features[]; ((.depends_on//[]) - $ids) == [] and (.verify|type=="string" and length>0))' "$FEAT" >/dev/null 2>&1 \
  || { echo "Invalid features.json: broken JSON, repeated ids, depends_on pointing to missing ids or features without verify"; exit 1; }
for f in logs/ STOP PAUSE loopkit.env __pycache__/; do grep -qxF "$f" .gitignore 2>/dev/null || echo "$f" >> .gitignore; done
[[ -d .git ]] || git init -q
git var GIT_COMMITTER_IDENT >/dev/null 2>&1 || { echo "Set a git identity first: git config --global user.name/user.email"; exit 1; }
[[ -f LEARNINGS.md ]] || cp "$KIT/templates/LEARNINGS.md" LEARNINGS.md   # durable lessons every worker reads
if [[ -f loopkit.env ]]; then cp -p loopkit.env logs/.loopkit.env; else rm -f logs/.loopkit.env; fi  # see restore_env
commit "loop start"
git rev-parse -q --verify HEAD >/dev/null || { echo "Could not make the first commit"; exit 1; }
[[ -f init.sh ]] && { timeout 30m bash init.sh >>logs/init.log 2>&1 9>&- || log "WARNING: init.sh failed (see logs/init.log)"; }

stall=0; replans=0; since_sweep=0; i=0
last_pass=$(passing)
log "Start | passing $last_pass | left $(remaining)"

# On a relaunch, keep numbering iterations so the logs do not mix with the previous run's
i0=$(ls logs/ | sed -nE 's/^iter-0*([0-9]+)-.*/\1/p' | sort -n | tail -1)
i0=${i0:-0}
for ((i=i0+1; i<=i0+MAX_ITER; i++)); do
  pause_if_requested
  [[ -f STOP ]] && { log "STOP found. Exiting (staying stopped until STOP is removed)."; exit 0; }
  if over_budget; then
    log "BUDGET reached: \$$(spent_usd) of \$$BUDGET_USD. Exiting (raise BUDGET_USD to continue)."
    notify "Loop stopped: budget reached (\$$(spent_usd) of \$$BUDGET_USD)"
    echo "budget reached" > logs/halted; exit 0
  fi
  rem=$(remaining)
  if (( rem == 0 )); then
    if security_pending; then security; continue; fi
    if usertest_pending; then usertest; continue; fi
    blocked=$(jq '[.features[]|select(.blocked==true)]|length' "$FEAT")
    log "DONE. Passing: $(passing). Blocked: $blocked"
    notify "Project done. Passing $(passing), blocked $blocked. Anything left for you is in DECISIONS.md"
    git rev-parse HEAD > logs/done   # the guard starts the loop again if a new commit (a change) lands later
    exit 0
  fi

  # First start of a plan: every pending verify must fail now. The ones that pass go to the replanner together
  if (( i0 == 0 )) && [[ ! -f logs/.baseline ]]; then
    : > logs/.baseline; green=()
    log "Checking that the pending verifies fail before any work"
    for id in $(jq -r '.features[]|select(.passes!=true and (.blocked//false)!=true)|.id' "$FEAT"); do
      [[ -f STOP || -f PAUSE ]] && break
      precheck_due "$id" && run_verify "$id" && { already_green "$id"; green+=("$id"); }
    done
    if (( ${#green[@]} )); then
      notify "Verifies that already pass before any work: ${green[*]}. Sent to the replanner"
      replan "verify already passes before any work (empty/weak verify or already done): ${green[*]}"; continue
    fi
  fi

  id=$(next_feature)
  if [[ -z "$id" ]]; then
    replan "$rem features left but none has its dependencies satisfied (blocked or a cycle)"; continue
  fi
  if (( $(field "$id" '.attempts//0') >= MAX_ATTEMPTS )); then
    replan "$id has failed $MAX_ATTEMPTS times. Last notes: $(field "$id" '.notes')"; continue
  fi
  if (( stall >= STALL_LIMIT )); then
    replan "$stall iterations in a row without a new passing feature"; continue
  fi

  # 0) RED FIRST: a verify that passes before the first worker checks nothing (or it is already done)
  if precheck_due "$id" && run_verify "$id"; then
    already_green "$id"; commit "harness: $id verify already passes"
    replan "$id: verify already passes before any work: empty/weak verify or already done"; continue
  fi

  log "Iter $i | $id | left $rem | passing $(passing)"
  cp "$FEAT" logs/.before.json
  commit "harness: before $id"; wpre=$(git rev-parse HEAD)
  note=""
  n=$(wc -l < LEARNINGS.md 2>/dev/null || echo 0)
  (( n > LEARNINGS_MAX )) && note="

NOTE FROM THE HARNESS: LEARNINGS.md has $n lines, over its cap of $LEARNINGS_MAX. Condense it in this session (merge entries, drop what is obsolete or specific to one feature)."

  # 1) WORKER: implements the feature the harness assigns
  grep -qxF "$id" logs/worked 2>/dev/null || echo "$id" >> logs/worked
  st=$(run_agent worker "$KIT/prompts/WORKER.md" "$MODEL" "ASSIGNED FEATURE:
$(jq --arg id "$id" '.features[]|select(.id==$id)' "$FEAT")$note")
  cmp -s "$FEAT" logs/.before.json || log "Worker touched features.json -> reverted"
  cp logs/.before.json "$FEAT"
  commit "harness: $id worker ($st)"
  revert_harness "$wpre" "$id"
  ok=0
  if [[ "$st" == stopped ]]; then
    log "$id: worker interrupted by STOP/PAUSE while waiting (not counted as an attempt)"; continue
  elif [[ "$st" == hung ]]; then
    fail_feat "$id" "hung: no output for ${HANG_SECONDS} s (session killed; logs/iter-$(printf %05d "$i")-worker.jsonl)"
  elif [[ "$st" != ok ]]; then
    fail_feat "$id" "worker ended with $st (timeout/max-turns = feature too big or stuck)"
  # 2) VERIFY: run by the harness, not by the agent
  elif ! run_verify "$id"; then
    fail_feat "$id" "verify failed: $(tail -c 600 "logs/verify-$id.log" | tr '\n' ' ')"
  else
    # 3) QA: a clean session that tries to prove it is not done. Its changes are thrown away
    clean_or_die; pre=$(git rev-parse HEAD); rm -f logs/qa-verdict.txt
    flags=$(red_flags "$wpre" "$id")
    [[ -n $flags ]] && log "$id red flags for the QA: $(tr '\n' ' ' <<<"$flags")"
    qst=$(run_agent qa "$KIT/prompts/QA.md" "$QA_MODEL" "FEATURE TO AUDIT:
$(jq --arg id "$id" '.features[]|select(.id==$id)' "$FEAT")${flags:+

RED FLAGS THE HARNESS FOUND IN WHAT THE WORKER CHANGED (git diff $wpre HEAD):
$flags}")
    git reset -q --hard "$pre"; git clean -fdq
    verdict=$(head -1 logs/qa-verdict.txt 2>/dev/null | tr -d '[:space:]')
    reason=$(tail -n +2 logs/qa-verdict.txt 2>/dev/null | head -c 800 | tr '\n' ' ')
    if [[ "$verdict" == PASS ]]; then
      set_feat "$id" '.passes=true | .notes=""'; progress "$id OK (verify + QA)${reason:+. QA note: $reason}"; log "$id PASS"; ok=1
    elif [[ "$verdict" == FAIL ]]; then
      fail_feat "$id" "QA: $reason"
    else
      log "$id: QA inconclusive ($qst). Retrying next iteration"
    fi
  fi
  commit "harness: $id $([[ $ok == 1 ]] && echo PASS || echo fail)"

  # 4) Progress, stalls and regressions
  now_pass=$(passing)
  if (( now_pass > last_pass )); then
    stall=0; replans=0; since_sweep=$(( since_sweep + now_pass - last_pass ))
  else
    (( ++stall ))
  fi
  last_pass=$now_pass
  if (( REGRESSION_EVERY > 0 && since_sweep >= REGRESSION_EVERY )); then
    regression_sweep; since_sweep=0; last_pass=$(passing)
  fi
  sleep "${LOOP_SLEEP:-5}"
done
log "MAX_ITER reached"; notify "Loop stopped: MAX_ITER reached"
