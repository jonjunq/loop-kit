#!/usr/bin/env bash
# End-to-end tests of the harness with a fake Claude (tests/mock-claude.py). No network, no cost.
# Needs: bash, git, jq, python3, curl, flock, timeout, tmux.   Usage: tests/run-tests.sh
set -uo pipefail
REPO=$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)
TMP=$(mktemp -d)
TS="loopkit-test-$$"   # private tmux server for the guard tests: real sessions are never touched
trap 'tmux -L "$TS" kill-server 2>/dev/null; rm -rf "$TMP" "${TMUX_TMPDIR:-/tmp}/tmux-$(id -u)/$TS"' EXIT
export CLAUDE_BIN="$REPO/tests/mock-claude.py" LOOP_SLEEP=0 GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
unset MODEL QA_MODEL BUDGET_USD NOTIFY_CMD NTFY_TOPIC PERMS
pass=0 fail=0

check() { # $1 = description, rest = command that must succeed
  local d=$1; shift
  if "$@" >/dev/null 2>&1; then pass=$((pass+1)); printf '  ok    %s\n' "$d"
  else fail=$((fail+1)); printf '  FAIL  %s\n' "$d"; fi
}
feature() { # id, depends_on (json array), priority
  printf '{"id":"%s","priority":%s,"depends_on":%s,"description":"[Base] %s","steps":[],"verify":"test -f done/%s","passes":false,"attempts":0,"blocked":false,"notes":""}' "$1" "$3" "$2" "$1" "$1"
}
project() { # $1 = name, rest = features json objects. Creates a fresh project with loopkit installed
  local p="$TMP/$1"; shift
  "$REPO/loopkit" init "$p" >/dev/null
  (IFS=,; echo "{\"features\":[$*]}") > "$p/features.json"
  printf '# Progress\n' > "$p/PROGRESS.md"; printf '# Decisions\n' > "$p/DECISIONS.md"
  : > "$p/loopkit.env"; mkdir -p "$p/mock"; echo src > "$p/src.txt"
  echo mock/ >> "$p/.git/info/exclude"   # the mock's scripts are not project files: resets must not undo them
  git -C "$p" add -A && git -C "$p" commit -qm plan
  echo "$p"
}
run() { (cd "$1" && shift && env "$@" timeout 120 ./loopkit/run.sh >/dev/null 2>&1); }
filler() { # $1 = project, $2 = count. A long history, so `git log | grep -m1` really gets SIGPIPE (pipefail traps)
  python3 -I - "$1" "$2" <<'PY' | git -C "$1" fast-import --quiet
import subprocess, sys
p, n = sys.argv[1], int(sys.argv[2])
ref = subprocess.check_output(["git", "-C", p, "symbolic-ref", "HEAD"], text=True).strip()
head = subprocess.check_output(["git", "-C", p, "rev-parse", "HEAD"], text=True).strip()
for i in range(1, n + 1):
    msg = f"filler commit {i:05d} {'x' * 60}\n"
    sys.stdout.write(f"commit {ref}\ncommitter t <t@t> {1700000000 + i} +0000\ndata {len(msg.encode())}\n{msg}")
    sys.stdout.write(f"from {head}\n\n" if i == 1 else "\n")
PY
}
fakesleep="$TMP/fakesleep"   # LOOPKIT_SLEEP: long waits are logged to $SLEPT instead of slept
printf '#!/bin/sh\necho "$1" >> "$SLEPT"\n' > "$fakesleep"; chmod +x "$fakesleep"
slept() { awk '{s += $1} END {print s + 0}' "$1/slept" 2>/dev/null || echo 0; }
alive() { [[ -f "$1" ]] && kill -0 "$(cat "$1")" 2>/dev/null; }
passes() { jq -r --arg id "$2" '.features[]|select(.id==$id)|.passes' "$1/features.json"; }
field() { jq -r --arg id "$2" ".features[]|select(.id==\$id)|$3" "$1/features.json"; }

echo "loopkit CLI"
P=$(project cli "$(feature F001 '[]' 1)")
check "init installs the harness" test -x "$P/loopkit/run.sh"
check "init ignores loopkit.env" grep -qxF loopkit.env "$P/.gitignore"
check "update refuses nothing when idle" "$REPO/loopkit" update "$P"
check "update keeps project files" test -f "$P/features.json"

echo "reset time of a usage limit (lib.sh)"
# shellcheck source=../kit/lib.sh
source "$REPO/kit/lib.sh"
near() { local e; e=$(reset_epoch "$1"); [[ -n $e ]] && (( e - $(date +%s) >= $2 - 2 && e - $(date +%s) <= $2 + 2 )); }
at() { local e; e=$(reset_epoch "$1"); (( e == $2 || e == $2 + 86400 )); }
check "epoch after 'usage limit reached|'" test "$(reset_epoch 'Claude AI usage limit reached|1793975400')" = 1793975400
check "'try again in 2h 30m'" near 'Please try again in 2h 30m.' 9000
check "'resets in 45 minutes'" near 'Limit reached, resets in 45 minutes' 2700
check "'resets 3pm (Europe/Madrid)' in that time zone" at "You've hit your limit · resets 3pm (Europe/Madrid)" "$(TZ=Europe/Madrid date -d 3pm +%s)"
check "'resets Nov 7, 3:30pm'" test "$(reset_epoch '5-hour limit reached ∙ resets Nov 7, 3:30pm')" = "$(date -d 'Nov 7 3:30pm' +%s)"
check "no time in the text, no reset" test -z "$(reset_epoch 'API Error: 529 overloaded')"
check "durations in seconds" test "$(secs 20m) $(secs 3h) $(secs 90)" = "1200 10800 90"

echo "happy path"
P=$(project happy "$(feature F001 '[]' 1)" "$(feature F002 '["F001"]' 2)" "$(feature F003 '["F002"]' 3)")
run "$P"
check "LEARNINGS.md is created and committed" git -C "$P" cat-file -e HEAD:LEARNINGS.md
check "no red flags for a clean diff" bash -c "! grep -q 'RED FLAGS' '$P/mock/prompt-qa'"
check "all features pass" test "$(jq '[.features[]|select(.passes)]|length' "$P/features.json")" = 3
check "log says DONE" grep -q 'DONE. Passing: 3' "$P/logs/loop.log"
check "QA changes were discarded" bash -c "! grep -q 'qa was here' '$P/src.txt' && ! test -e '$P/qa-untracked.txt'"
check "PASS commits for the demo and the roadmap" git -C "$P" log --format=%s --grep='^harness: F002 PASS$'
check "progress written" grep -q 'F003 OK (verify + QA)' "$P/PROGRESS.md"
check "notification logged" grep -q 'Project done' "$P/logs/notify.log"

echo "QA failure, cheating worker, verify failure"
P=$(project qa "$(feature F001 '[]' 1)" "$(feature F002 '[]' 2)")
printf 'FAIL|the button does nothing\n' > "$P/mock/qa-F001"
printf 'cheat\n' > "$P/mock/worker-F002"
run "$P"
check "QA FAIL counts as an attempt and is retried" test "$(field "$P" F001 .attempts)" = 1
check "QA reason reaches the notes history" grep -q 'QA: the button does nothing' "$P/PROGRESS.md"
check "cheat is reverted and fails the verify" grep -q 'Worker touched features.json -> reverted' "$P/logs/loop.log"
check "both end up passing" test "$(passes "$P" F001)$(passes "$P" F002)" = truetrue

echo "the worker cannot change the harness"
P=$(project harness "$(feature F001 '[]' 1)")
echo 'DEMO_PORT=3000' > "$P/demo.env"; echo 'BUDGET_USD=100' > "$P/loopkit.env"
git -C "$P" add -A && git -C "$P" commit -qm "demo config"
printf 'harness\n' > "$P/mock/worker-F001"
run "$P"
check "logged" grep -q 'Worker touched the harness -> reverted' "$P/logs/loop.log"
check "prompt edit reverted" cmp -s "$P/loopkit/prompts/QA.md" "$REPO/kit/prompts/QA.md"
check "new file in loopkit/ removed" test ! -e "$P/loopkit/evil.sh"
check "demo.env reverted" test "$(cat "$P/demo.env")" = DEMO_PORT=3000
check "loopkit.env (git-ignored) reverted" test "$(cat "$P/loopkit.env")" = BUDGET_USD=100
check "the feature still passes" test "$(passes "$P" F001)" = true

echo "red flags for the QA"
P=$(project redflags "$(feature F001 '[]' 1)")
mkdir -p "$P/tests"; printf "it('works', () => { expect(1).toBe(1) })\n" > "$P/tests/old_test.py"
seq 100 > "$P/LEARNINGS.md"
git -C "$P" add -A && git -C "$P" commit -qm "old test"
printf 'weaken\n' > "$P/mock/worker-F001"
run "$P"
check "deleted test reaches the QA" grep -q 'test files deleted: tests/old_test.py' "$P/mock/prompt-qa"
check "skipped test reaches the QA" grep -q 'tests disabled: 1 lines with skip' "$P/mock/prompt-qa"
check "fewer assertions reach the QA" grep -q 'fewer assertions in the tests: 1' "$P/mock/prompt-qa"
check "...and the log" grep -q 'F001 red flags for the QA' "$P/logs/loop.log"
check "an oversized LEARNINGS.md gets the worker a note" grep -q 'LEARNINGS.md has 100 lines' "$P/mock/prompt-worker"

echo "red before starting"
P=$(project green "$(feature F001 '[]' 1)" \
  '{"id":"F002","priority":2,"depends_on":[],"description":"[Base] weak","steps":[],"verify":"true","passes":false,"attempts":0,"blocked":false,"notes":""}' \
  '{"id":"F003","priority":3,"depends_on":["F001"],"description":"[Base] Full regression","steps":[],"verify":"test -f done/F001","passes":false,"attempts":0,"blocked":false,"notes":""}' \
  '{"id":"F004","priority":4,"depends_on":["F001"],"description":"[Base] built by F001","steps":[],"verify":"test -f done/F001","passes":false,"attempts":0,"blocked":false,"notes":""}')
printf 'none\n' > "$P/mock/qa-F001"
run "$P"
check "first start: a verify that already passes goes to the replanner" grep -q 'Replan 1/5: verify already passes before any work (empty/weak verify or already done): F002$' "$P/logs/loop.log"
check "...noted in PROGRESS.md" grep -q 'F002: verify already passes before any work' "$P/PROGRESS.md"
check "before its first worker too (dependency already built it)" grep -qE 'Replan [0-9]/5: F004: verify already passes before any work' "$P/logs/loop.log"
check "regression gates are not prechecked" bash -c "! grep -q 'F003: verify already passes' '$P/logs/loop.log'"
check "a retry after an inconclusive QA is not prechecked" bash -c "grep -q 'F001: QA inconclusive' '$P/logs/loop.log' && ! grep -q 'F001: verify already passes' '$P/logs/loop.log'"
check "the same verify is not sent twice: all pass in the end" test "$(jq '[.features[]|select(.passes)]|length' "$P/features.json")" = 4

echo "usage limit with a reset time"
P=$(project limit "$(feature F001 '[]' 1)")
printf 'limit-at\n' > "$P/mock/worker-F001"
run "$P" LOOPKIT_SLEEP="$fakesleep" SLEPT="$P/slept" MOCK_RESET_IN=7200
wait_s=$(sed -nE 's/.*usage limit. Waiting until .* \(([0-9]+)s\).*/\1/p' "$P/logs/loop.log")
check "waits until the reset plus the margin, not a blind backoff" test "${wait_s:-0}" -ge 7318 -a "${wait_s:-0}" -le 7322
check "...and sleeps exactly that" test "$(slept "$P")" = "${wait_s:-x}"
check "...telling you when it resumes" grep -q 'it resumes by itself at' "$P/logs/notify.log"
check "resumes the same session" test "$(head -1 "$P/mock/resumed")" = "$(head -1 "$P/logs/iter-00001-worker.jsonl" | jq -r .session_id)"
check "...and the feature passes without a failed attempt" test "$(passes "$P" F001)$(field "$P" F001 .attempts)" = true0
check "logs/waiting is gone" test ! -e "$P/logs/waiting"
P=$(project noresume "$(feature F001 '[]' 1)")
printf 'limit-at\n' > "$P/mock/worker-F001"; touch "$P/mock/resume-fail"
run "$P" LOOPKIT_SLEEP="$fakesleep" SLEPT="$P/slept" MOCK_RESET_IN=60
check "a resume that fails starts a new session" grep -q 'could not resume session' "$P/logs/loop.log"
check "...which builds the feature" test "$(passes "$P" F001)$(field "$P" F001 .attempts)" = true0
P=$(project oldlimit "$(feature F001 '[]' 1)")
printf 'limit\n' > "$P/mock/worker-F001"
run "$P" LOOPKIT_SLEEP="$fakesleep" SLEPT="$P/slept"
check "a limit with no usable reset time falls back to the backoff" test "$(slept "$P")" = 60
check "...and then goes on" test "$(passes "$P" F001)" = true

echo "hung sessions and leftover processes"
P=$(project hung "$(feature F001 '[]' 1)" "$(feature F002 '[]' 2)")
printf 'hang\n' > "$P/mock/worker-F001"; printf 'server\n' > "$P/mock/worker-F002"
start=$(date +%s); run "$P" HANG_SECONDS=2; took=$(( $(date +%s) - start ))
check "a silent session is killed as a failed attempt" grep -q 'F001 FAILS (attempt 1): hung: no output for 2 s' "$P/PROGRESS.md"
check "...long before ITER_TIMEOUT" test "$took" -lt 60
check "...together with what it started, detached or not" bash -c "test -f '$P/mock/hang.pid' && ! kill -0 \$(cat '$P/mock/hang.pid') 2>/dev/null"
check "...and the retry passes" test "$(passes "$P" F001)" = true
check "a server left running by a session is killed" bash -c "grep -q 'worker: killed 1 processes' '$P/logs/loop.log' && ! kill -0 \$(cat '$P/mock/server.pid') 2>/dev/null"

echo "stuck feature -> replan split"
P=$(project stuck "$(feature F001 '[]' 1)" "$(feature F002 '["F001"]' 2)")
printf 'noimpl\nnoimpl\nnoimpl\n' > "$P/mock/worker-F001"
run "$P"
check "replanned" grep -q 'Replan 1/5' "$P/logs/loop.log"
check "stuck feature blocked, split one passes" test "$(field "$P" F001 .blocked)$(passes "$P" F001a)" = truetrue
check "dependent feature passes" test "$(passes "$P" F002)" = true
check "replanner code changes discarded" bash -c "! grep -q 'replan touched code' '$P/src.txt'"
check "replanner decisions kept" grep -q -- '- replan' "$P/DECISIONS.md"

echo "replanner breaks features.json"
P=$(project broken "$(feature F001 '[]' 1)" "$(feature F002 '[]' 2)")
printf 'noimpl\nnoimpl\nnoimpl\n' > "$P/mock/worker-F001"; printf 'break\n' > "$P/mock/replan"
run "$P"
check "invalid plan restored" grep -q 'left an invalid features.json -> restored' "$P/logs/loop.log"
check "unsolved feature blocked by the harness" test "$(field "$P" F001 .blocked)" = true
check "the rest still passes" test "$(passes "$P" F002)" = true

echo "transient failures and timeouts"
P=$(project transient "$(feature F001 '[]' 1)")
printf 'maxturns\n' > "$P/mock/worker-F001"
run "$P"
check "max_turns counts as a failed attempt" grep -q 'worker ended with max_turns' "$P/PROGRESS.md"
check "then it passes" test "$(passes "$P" F001)" = true

echo "STOP and budget"
P=$(project stop "$(feature F001 '[]' 1)")
touch "$P/STOP"; run "$P"
check "STOP exits before working and stays" bash -c "grep -q 'STOP found' '$P/logs/loop.log' && test -e '$P/STOP' && ! ls '$P'/logs/iter-* 2>/dev/null"
P=$(project budget "$(feature F001 '[]' 1)" "$(feature F002 '[]' 2)" "$(feature F003 '[]' 3)")
run "$P" BUDGET_USD=1.5 MOCK_COST=0.5
check "budget stops the loop" grep -q 'BUDGET reached' "$P/logs/loop.log"
check "...and leaves logs/halted for the guard" grep -q 'budget reached' "$P/logs/halted"
check "...after two sessions' worth of features" test "$(jq '[.features[]|select(.passes)]|length' "$P/features.json")" = 2
echo "BUDGET_USD=100" > "$P/loopkit.env"; run "$P"
check "loopkit.env raises the budget and it resumes" test "$(passes "$P" F003)" = true
check "iteration numbering continues after a relaunch" bash -c "ls '$P/logs' | grep -q 'iter-00003-worker'"
check "a relaunch clears logs/halted and DONE writes logs/done" bash -c "! test -e '$P/logs/halted' && test \"\$(cat '$P/logs/done')\" = \"\$(git -C '$P' rev-parse HEAD)\""

echo "PAUSE"
P=$(project pause "$(feature F001 '[]' 1)")
touch "$P/PAUSE"
(cd "$P" && timeout 120 ./loopkit/run.sh >/dev/null 2>&1) & bg=$!
for _ in $(seq 50); do [[ -f "$P/logs/paused" ]] && break; sleep 0.2; done
check "waits with logs/paused" test -f "$P/logs/paused"
echo '# owner tweak' >> "$P/loopkit/prompts/WORKER.md"; echo 'MAX_TURNS=301' >> "$P/loopkit.env"
git -C "$P" commit -qam "change: tweak the worker prompt [no usertest]"
rm "$P/PAUSE"; wait $bg
check "restarts itself after the pause and finishes" bash -c "grep -q 'Pause over' '$P/logs/loop.log' && test \"\$(grep -c '] Start' '$P/logs/loop.log')\" = 2 && grep -q DONE '$P/logs/loop.log'"
check "harness changes made during the pause are kept" bash -c "grep -q 'owner tweak' '$P/loopkit/prompts/WORKER.md' && grep -q MAX_TURNS=301 '$P/loopkit.env' && ! grep -q 'touched the harness' '$P/logs/loop.log'"

echo "notifications"
P=$(project notify "$(feature F001 '[]' 1)")
printf 'NOTIFY_CMD='\''echo "$1" >> %s/sent.txt'\''\n' "$P" > "$P/loopkit.env"
run "$P"
check "NOTIFY_CMD from loopkit.env gets the message once" test "$(grep -c 'Project done' "$P/sent.txt")" = 1
check "a script path as NOTIFY_CMD gets the message as its argument" bash -c "cd '$P' && printf '#!/bin/sh\necho \"\$1\" > got.txt\n' > n.sh && chmod +x n.sh && NOTIFY_CMD='$P/n.sh' ./loopkit/notify.sh 'hi there' && test \"\$(cat got.txt)\" = 'hi there'"
check "notify.sh helper works" bash -c "cd '$P' && ./loopkit/notify.sh hello && grep -q hello sent.txt"

echo "automatic user test"
P=$(project usertest "$(feature F001 '[]' 1)")
PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("",0)); print(s.getsockname()[1])')
cat > "$P/usertest.env" <<EOF
USERTEST_PORT=$PORT
USERTEST_BUILD='true'
USERTEST_SEED='echo seeded > "\$USERTEST_DATA/seed.txt"'
USERTEST_START='exec python3 -m http.server "\$USERTEST_PORT" --bind 127.0.0.1'
USERTEST_INFO='static test server'
USERTEST_ZONES=("alpha|the alpha zone" "beta|the beta zone")
EOF
filler "$P" 3000   # long history before the batch: since_batch's git log is cut off by awk (pipefail traps)
git -C "$P" add -A && git -C "$P" commit -qm "change: usertest config"
printf 'bug\n' > "$P/mock/tester-alpha"
run "$P" USERTEST_ROUNDS=3
check "testers reached the isolated copy" grep -q 'copy reachable: True' "$P"/logs/usertest-*/report-alpha.md
check "round 1 created a fix feature" git -C "$P" log --format=%s --grep='^usertest: round 1 · fix features: F002'
check "the loop built the fix" test "$(passes "$P" F002)" = true
check "round 2 found nothing and closed the batch" git -C "$P" log --format=%s --grep='^usertest: round 2 · nothing to fix'
check "...and no round 3 even with USERTEST_ROUNDS=3" test "$(git -C "$P" log --format=%s | grep -c '^usertest: round')" = 2
check "tester/triage code changes discarded" bash -c "! grep -qE 'tester was here|triage touched code' '$P/src.txt'"
check "the copy was shut down" bash -c "! curl -sf -o /dev/null http://127.0.0.1:$PORT/"

echo "batch without user test"
P=$(project nousertest "$(feature F001 '[]' 1)")
PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("",0)); print(s.getsockname()[1])')
cat > "$P/usertest.env" <<EOF
USERTEST_PORT=$PORT
USERTEST_START='exec python3 -m http.server "\$USERTEST_PORT" --bind 127.0.0.1'
USERTEST_ZONES=("alpha|the alpha zone")
EOF
filler "$P" 3000   # long history: the check must hold even when git log is cut off by grep -m1
git -C "$P" add -A && git -C "$P" commit -qm "change: polish only [no usertest]"
printf 'bug\n' > "$P/mock/tester-alpha"
run "$P"
check "[no usertest] skips the user test" bash -c "! git -C '$P' log --format=%s | grep -q '^usertest: round'"
check "...and the batch still finishes" test "$(passes "$P" F001)" = true

echo "automatic security review"
P=$(project security "$(feature F001 '[]' 1)")
PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("",0)); print(s.getsockname()[1])')
cat > "$P/usertest.env" <<EOF
USERTEST_PORT=$PORT
USERTEST_START='exec python3 -m http.server "\$USERTEST_PORT" --bind 127.0.0.1'
USERTEST_ZONES=("alpha|the alpha zone")
EOF
git -C "$P" add -A && git -C "$P" commit -qm "change: usertest config"
printf 'finding\n' > "$P/mock/security-backend"
run "$P"
check "two reviewers wrote their reports" bash -c "ls '$P'/logs/security-*/report-backend.md '$P'/logs/security-*/report-frontend-ops.md"
check "round 1 turned the finding into a fix feature" git -C "$P" log --format=%s --grep='^security: round 1 · fix features: F002'
check "the loop built the security fix" test "$(passes "$P" F002)" = true
check "the security round ran before the user test" bash -c "git -C '$P' log --reverse --format=%s | grep -m1 -E '^(security|usertest): round' | grep -q '^security'"
check "only one security round per batch" test "$(git -C "$P" log --format=%s | grep -c '^security: round')" = 1
check "reviewer and triage code changes discarded" bash -c "! grep -qE 'reviewer was here|security triage touched code' '$P/src.txt' && ! test -e '$P/reviewer-untracked.txt'"
check "triage decisions kept" grep -q 'security triage: 1 findings' "$P/DECISIONS.md"
order() { grep -oE 'Security review, round 1:|User test, round 1:|DONE' "$P/logs/loop.log" | cut -c1-4 | tr '\n' ' '; }
check "DONE only after the security review and the user test" test "$(order)" = "Secu User DONE "
check "...and logs/done is the final commit" test "$(cat "$P/logs/done")" = "$(git -C "$P" rev-parse HEAD)"
jq --argjson f "$(feature F009 '[]' 9)" '.features += [$f]' "$P/features.json" > "$TMP/f.json" && mv "$TMP/f.json" "$P/features.json"
git -C "$P" commit -qam "change: add F009"
run "$P"
check "a change: commit gets a new security round" test "$(git -C "$P" log --format=%s | grep -c '^security: round')" = 2
check "...which found nothing this time" bash -c "git -C '$P' log --format=%s | grep -m1 '^security: round' | grep -q 'nothing to fix'"
P=$(project nosecurity "$(feature F001 '[]' 1)")
run "$P" SECURITY_ROUNDS=0
check "SECURITY_ROUNDS=0 skips the review" bash -c "grep -q DONE '$P/logs/loop.log' && ! git -C '$P' log --format=%s | grep -q '^security: round' && ! ls -d '$P'/logs/security-* 2>/dev/null"

echo "demo"
P=$(project demo "$(feature F001 '[]' 1)" "$(feature F002 '[]' 2)")
DPORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("",0)); print(s.getsockname()[1])')
mkdir -p "$P/seed"; echo v0 > "$P/version.txt"; echo s1 > "$P/seed/s"
cat > "$P/demo.env" <<EOF
DEMO_PORT=$DPORT
DEMO_BUILD="test ! -f broken && cp version.txt build.txt"
DEMO_START="exec python3 -m http.server \$PORT --bind 127.0.0.1"
DEMO_RESEED="date +%s%N > .demo/data"
DEMO_RESEED_PATHS="^seed/"
EOF
git -C "$P" add -A && git -C "$P" commit -qm "demo config"
(cd "$P" && echo v1 > version.txt && git add -A && git commit -qm "F001" && git commit -q --allow-empty -m "harness: F001 PASS")
INTERVAL=1 bash -c "cd '$P' && exec ./loopkit/demo.sh" >/dev/null 2>&1 & demo=$!
get() { for _ in $(seq 40); do r=$(curl -s "http://127.0.0.1:$DPORT/build.txt"); [[ "$r" == "$1" ]] && return 0; sleep 0.25; done; return 1; }
check "demo serves the passing commit" get v1
(cd "$P" && echo v2 > version.txt && git commit -qam "wip")
sleep 3; check "ignores work that has not passed" get v1
(cd "$P" && touch broken && git add -A && git commit -qm F002 && git commit -q --allow-empty -m "harness: F002 PASS")
sleep 4; check "keeps the previous version when the build fails" get v1
data1=$(cat "$TMP/demo-demo/.demo/data")
(cd "$P" && rm broken && echo v3 > version.txt && echo s2 > seed/s && git add -A && git commit -qm F003 && git commit -q --allow-empty -m "harness: F003 PASS")
check "updates to the next passing commit" get v3
reseeded() { for _ in $(seq 40); do [[ "$(cat "$TMP/demo-demo/.demo/data" 2>/dev/null)" != "$data1" ]] && return 0; sleep 0.25; done; return 1; }
check "recreates demo data when the seed changes" reseeded
kill $demo; wait $demo 2>/dev/null
check "stops its server" bash -c "! curl -sf -o /dev/null http://127.0.0.1:$DPORT/"

echo "guard auto-start"
P=$(project auto "$(feature F001 '[]' 1)")
tmux -L "$TS" -f /dev/null new-session -d -s loop -n loop -c "$P"
waitfor() { local n=$1; shift; for _ in $(seq $((n * 4))); do "$@" >/dev/null 2>&1 && return 0; sleep 0.25; done; return 1; }
starts() { grep -c '] Start' "$P/logs/loop.log" 2>/dev/null; }
built() { test "$(passes "$P" "$1")" = true; }   # evaluated on every poll, unlike an inline $(...)
done_at_head() { test "$(cat "$P/logs/done" 2>/dev/null)" = "$(git -C "$P" rev-parse HEAD)"; }
finished() { built "$1" && done_at_head; }   # built and the run is over (the end-of-batch reviews included)
guard() { (cd "$P" && AUTO_RESUME=1 GUARD_INTERVAL=1 TMUX_SOCKET="$TS" exec python3 loopkit/roadmap/guard.py >> "$TMP/guard.out" 2>&1) & gpid=$!; }
add_feature() { # $1 = id: commits a change that adds a pending feature
  jq --argjson f "$(feature "$1" '[]' 9)" '.features += [$f]' "$P/features.json" > "$TMP/f.json" && mv "$TMP/f.json" "$P/features.json"
  git -C "$P" commit -qam "change: add $1"
}
guard
check "starts a loop that never finished" waitfor 60 built F001
check "...and the loop writes logs/done" waitfor 20 done_at_head
sleep 4; check "no start while finished and nothing new" test "$(starts)" = 1
add_feature F002
check "a new commit starts it again" waitfor 60 finished F002
touch "$P/STOP"; add_feature F003; sleep 4
check "STOP keeps it stopped" test "$(starts)" = 2
rm "$P/STOP"
check "rm STOP starts it" waitfor 60 finished F003
echo "needs a human" > "$P/logs/halted"; add_feature F004; sleep 4
check "logs/halted keeps it stopped" test "$(starts)" = 3
rm "$P/logs/halted"
check "removing logs/halted starts it" waitfor 60 finished F004
echo '{' > "$P/features.json"; git -C "$P" commit -qam "broken plan"
check "gives up after 3 starts that die at once" waitfor 60 grep -q 'dies right after starting' "$P/logs/notify.log"
check "...and waits for the next commit" test "$(git -C "$P" log -1 --format=%H)" = "$(jq -r .gave_up "$P/logs/guard.json")"
git -C "$P" checkout -q HEAD~1 -- features.json; add_feature F005
check "a fixing commit makes it start again" waitfor 60 finished F005
kill $gpid; wait $gpid 2>/dev/null
touch "$P/STOP"; add_feature F006
python3 -c "import json,time; json.dump({'state':'stopping','reset_at':int(time.time()*1000)-120000}, open('$P/logs/guard.json','w'))"
guard
check "after a usage stop, the guard removes its STOP" waitfor 20 test ! -e "$P/STOP"
check "...and starts the loop when the window has renewed" waitfor 60 finished F006
check "...saying so" grep -q 'usage renewed: relaunching' "$P/logs/notify.log"
kill $gpid; wait $gpid 2>/dev/null
P=$(project guardwait "$(feature F001 '[]' 1)")
mkdir -p "$P/logs"
python3 -c "import json,time; print(json.dumps({'type':'rate_limit_event','rate_limit_info':{'status':'allowed','unifiedWindows':{'five_hour':{'utilization':0.99,'resetsAt':int(time.time())+3600}}}}))" > "$P/logs/iter-00001-worker.jsonl"
date +%s > "$P/logs/waiting"
flock "$P/logs/.lock" sleep 30 & lockpid=$!   # a "running" loop
(cd "$P" && GUARD_INTERVAL=1 exec python3 loopkit/roadmap/guard.py >> "$TMP/guard.out" 2>&1) & gpid=$!
sleep 4; check "the guard does not stop a loop that is waiting out a limit" test ! -e "$P/STOP"
rm "$P/logs/waiting"
check "...but does once it is working again" waitfor 20 test -e "$P/STOP"
kill $gpid; pkill -P $lockpid; wait $gpid $lockpid 2>/dev/null
check "tmux.sh creates the session with loop, roadmap and guard windows" bash -c "cd '$P' && TMUX_SOCKET='$TS' TMUX_SESSION=boot ROADMAP_PORT=0 ./loopkit/tmux.sh && test \"\$(tmux -L '$TS' list-windows -t boot -F '#{window_name}' | tr '\n' ' ')\" = 'loop roadmap guard '"
check "...and does nothing if it already exists" bash -c "cd '$P' && TMUX_SOCKET='$TS' TMUX_SESSION=boot ./loopkit/tmux.sh | grep -q 'already exists'"
tmux -L "$TS" kill-server 2>/dev/null

echo
echo "$pass passed, $fail failed"
(( fail == 0 ))
