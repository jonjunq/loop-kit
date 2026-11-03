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
passes() { jq -r --arg id "$2" '.features[]|select(.id==$id)|.passes' "$1/features.json"; }
field() { jq -r --arg id "$2" ".features[]|select(.id==\$id)|$3" "$1/features.json"; }

echo "loopkit CLI"
P=$(project cli "$(feature F001 '[]' 1)")
check "init installs the harness" test -x "$P/loopkit/run.sh"
check "init ignores loopkit.env" grep -qxF loopkit.env "$P/.gitignore"
check "update refuses nothing when idle" "$REPO/loopkit" update "$P"
check "update keeps project files" test -f "$P/features.json"

echo "happy path"
P=$(project happy "$(feature F001 '[]' 1)" "$(feature F002 '["F001"]' 2)" "$(feature F003 '["F002"]' 3)")
run "$P"
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
rm "$P/PAUSE"; wait $bg
check "restarts itself after the pause and finishes" bash -c "grep -q 'Pause over' '$P/logs/loop.log' && test \"\$(grep -c '] Start' '$P/logs/loop.log')\" = 2 && grep -q DONE '$P/logs/loop.log'"

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
check "tmux.sh creates the session with loop, roadmap and guard windows" bash -c "cd '$P' && TMUX_SOCKET='$TS' TMUX_SESSION=boot ROADMAP_PORT=0 ./loopkit/tmux.sh && test \"\$(tmux -L '$TS' list-windows -t boot -F '#{window_name}' | tr '\n' ' ')\" = 'loop roadmap guard '"
check "...and does nothing if it already exists" bash -c "cd '$P' && TMUX_SOCKET='$TS' TMUX_SESSION=boot ./loopkit/tmux.sh | grep -q 'already exists'"
tmux -L "$TS" kill-server 2>/dev/null

echo
echo "$pass passed, $fail failed"
(( fail == 0 ))
