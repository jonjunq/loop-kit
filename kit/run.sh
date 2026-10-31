#!/usr/bin/env bash
# loop-kit harness. It picks the feature, runs its verify command and keeps the score.
# Agents implement (worker), audit (QA) and replan (replanner), but never mark anything as done.
# Usage, from the project root inside tmux:  ./loopkit/run.sh
# With the usage guard running with AUTO_RESUME=1 nobody needs to start it by hand: the guard starts it whenever there
# is work (pending features, or new commits since the last DONE).
# Stop and stay stopped: touch STOP (the current iteration ends; STOP stays). Resume: rm STOP.
# Pause for manual changes without relaunching: touch PAUSE (the current iteration ends, logs/paused appears and it
# waits); rm PAUSE and the harness restarts itself (re-reading run.sh, prompts and features.json). See prompts/CHANGE.md.
# Markers for the guard: logs/done (HEAD at the last DONE) and logs/halted (stopped, needs a human).
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
CLAUDE_BIN="${CLAUDE_BIN:-claude}"
# ------------------------------------------------------------------------------------------------------

FEAT=features.json
mkdir -p logs
exec 9>logs/.lock
flock -n 9 || { echo "Another run.sh is already running in this folder"; exit 1; }
rm -f logs/paused logs/halted

log()      { echo "[$(date '+%F %T')] $*" | tee -a logs/loop.log; }
commit()   { git add -A >/dev/null 2>&1 && git commit --no-verify -qm "$1" >/dev/null 2>&1; true; }
progress() { echo "- $(date '+%F %T') [harness] $*" >> PROGRESS.md; }
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

# Starts a clean Claude Code session. Prints: ok | max_turns | timeout | error | transient
run_once() { # $1 = role, $2 = prompt file, $3 = model, $4 = extra text
  local out margs=() rc res
  out="logs/iter-$(printf %05d "$i")-$1.jsonl"
  [[ -n "$3" ]] && margs=(--model "$3")
  # shellcheck disable=SC2086  # PERMS holds several words on purpose
  LOOPKIT_ROLE="$1" timeout -k 60 "$ITER_TIMEOUT" "$CLAUDE_BIN" -p "$(cat "$2")${4:+

$4}" $PERMS --max-turns "$MAX_TURNS" "${margs[@]}" \
    --output-format stream-json --verbose >>"$out" 2>>"${out%.jsonl}.err"
  rc=$?
  (( rc == 124 || rc == 137 )) && { echo timeout; return; }
  res=$(grep -E '"type" *: *"result"' "$out" | tail -1)
  [[ -z "$res" ]] && { echo transient; return; }   # no result at all: network, login, limit before starting...
  case "$(jq -r '.subtype' <<<"$res")" in
    error_max_turns) echo max_turns ;;
    success) if [[ "$(jq -r '.is_error' <<<"$res")" != true ]]; then echo ok
             elif jq -r '.result // ""' <<<"$res" | grep -qiE 'limit|rate|overload|429|529|quota|credit|api error|network'; then echo transient
             else echo error; fi ;;
    *) echo error ;;
  esac
}
# Same as run_once, but on a transient failure (usage limit, network) waits with backoff and retries
run_agent() {
  local st backoff=60
  while :; do
    st=$(run_once "$@")
    [[ "$st" != transient ]] && { echo "$st"; return; }
    [[ -f STOP ]] && { echo error; return; }
    log "$1: transient failure (usage limit / network). Waiting ${backoff}s" >&2
    (( backoff == 3600 )) && notify "Loop waiting: usage limit or network down"
    sleep "$backoff"; backoff=$(( backoff*2 > 3600 ? 3600 : backoff*2 ))
  done
}

run_verify() { # $1 = id. Exit 0 when the verify passes
  local cmd; cmd=$(field "$1" .verify)
  timeout -k 30 "$VERIFY_TIMEOUT" bash -c "$cmd" >"logs/verify-$1.log" 2>&1
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

# ---------- Security review ----------
# When the work runs out, before the user test: read-only reviewers look for exploitable flaws in the code (their
# changes are discarded) and a triage turns the verified ones into [Security N] features. Rounds are counted like the
# user test's: "security: round" commits since the last "change:" commit; a round with nothing to fix ends the batch.
since_batch() { git log --format=%s | awk '/^change:/{exit} {print}'; }  # commit subjects since the last change
security_pending() {
  (( SECURITY_ROUNDS > 0 )) || return 1
  (( $(since_batch | grep -c '^security: round') < SECURITY_ROUNDS )) || return 1
  ! since_batch | grep -m1 '^security: round' | grep -q 'nothing to fix'
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
  (( $(since_batch | grep -c '^usertest: round') < USERTEST_ROUNDS )) || return 1
  ! since_batch | grep -m1 '^usertest: round' | grep -q 'nothing to fix'
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
commit "loop start"
git rev-parse -q --verify HEAD >/dev/null || { echo "Could not make the first commit"; exit 1; }
[[ -f init.sh ]] && { timeout 30m bash init.sh >>logs/init.log 2>&1 || log "WARNING: init.sh failed (see logs/init.log)"; }

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

  log "Iter $i | $id | left $rem | passing $(passing)"
  cp "$FEAT" logs/.before.json

  # 1) WORKER: implements the feature the harness assigns
  st=$(run_agent worker "$KIT/prompts/WORKER.md" "$MODEL" "ASSIGNED FEATURE:
$(jq --arg id "$id" '.features[]|select(.id==$id)' "$FEAT")")
  cmp -s "$FEAT" logs/.before.json || log "Worker touched features.json -> reverted"
  cp logs/.before.json "$FEAT"
  commit "harness: $id worker ($st)"
  ok=0
  if [[ "$st" != ok ]]; then
    fail_feat "$id" "worker ended with $st (timeout/max-turns = feature too big or stuck)"
  # 2) VERIFY: run by the harness, not by the agent
  elif ! run_verify "$id"; then
    fail_feat "$id" "verify failed: $(tail -c 600 "logs/verify-$id.log" | tr '\n' ' ')"
  else
    # 3) QA: a clean session that tries to prove it is not done. Its changes are thrown away
    clean_or_die; pre=$(git rev-parse HEAD); rm -f logs/qa-verdict.txt
    qst=$(run_agent qa "$KIT/prompts/QA.md" "$QA_MODEL" "FEATURE TO AUDIT:
$(jq --arg id "$id" '.features[]|select(.id==$id)' "$FEAT")")
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
