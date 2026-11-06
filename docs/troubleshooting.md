# Troubleshooting

**"Another run.sh is already running in this folder"**
Another harness holds `logs/.lock`. Find it with `pgrep -af loopkit/run.sh` (after a PAUSE restart the process
shows the absolute path). Do not delete the lock file to "fix" it.

**It halted: "Needs a human"**
`MAX_REPLANS` replans did not make progress. Read the last entries of `DECISIONS.md` and `logs/loop.log`, fix
`features.json` / `SPEC.md` (or run `CHANGE.md` with Claude), then delete `logs/halted` (the guard starts the loop
again) or run `./loopkit/run.sh`.

**"HALTED: uncommitted changes that a reset would wipe"**
git could not commit: no identity (`git config --global user.name/user.email`), disk full, or a hook. Fix it,
commit or stash what is there, then delete `logs/halted` or run `./loopkit/run.sh`.

**A feature keeps failing**
`features.json` → its `notes`, then `logs/verify-<id>.log` and the QA verdict reason in `PROGRESS.md`. The usual
causes: the feature is too big (split it with `CHANGE.md`), the verify is flaky (timing, ports in use, a server left
running) or depends on something outside the sandbox.

**"verify already passes before any work"**
The harness ran a feature's verify before its first worker and it passed: either it checks nothing (a filter that
matches no test, a check that is always true) or an earlier feature already built it. The replanner gets it and
rewrites the verify or says which feature built it (`DECISIONS.md`); the feature then goes on. A "Full regression"
gate is exempt. If you meant it, write a verify that fails until the feature exists.

**"hung: no output for N s"**
A session stopped producing output for `HANG_SECONDS` and was killed (with whatever it had started). Look at the end of
`logs/iter-NNNNN-worker.jsonl` for the last tool call: usually a command that never returns (a server started in the
foreground, an interactive prompt, a test waiting for input). If a single command of yours legitimately runs longer
than that in silence, raise `HANG_SECONDS`.

**"Worker touched the harness -> reverted"**
The worker changed `loopkit/`, `loopkit.env`, `demo.env` or `usertest.env`; the harness put them back. To change the
harness yourself: `touch PAUSE`, wait for `logs/paused`, edit and commit, `rm PAUSE` (or `prompts/CHANGE.md`).
Changes you make to them while the loop is running (not paused) are reverted too.

**It says "Waiting until … for the usage limit"**
It hit the usage limit and sleeps until the reset Claude Code announced, then resumes the interrupted session. The
time is in `logs/waiting`. `touch STOP` (or `PAUSE`) ends the wait; it is not counted as an attempt.

**Everything fails at once / sessions end immediately**
Check `logs/iter-*-worker.err` and the last `result` line of the latest `logs/iter-*-worker.jsonl`. Typical: Claude
Code logged out, usage limit (the harness waits by itself until the reset), no network, or `PERMS` refusing what the
worker needs.

**Workers get stuck asking for permission**
With `--permission-mode auto` nobody approves blocked actions. Either run in a sandbox with
`--dangerously-skip-permissions` (see [isolation](isolation.md)) or make sure the plan does not need the refused action.

**Verify commands time out late in the project**
The e2e suite grew. Raise `VERIFY_TIMEOUT` (e.g. `45m`) and keep per-feature verifies targeted; use the full suite
only in regression features.

**The loop does not start by itself**
The guard starts it only with `AUTO_RESUME=1`, when the loop's pane (`TMUX_TARGET`, `loop:loop` by default) is idle
at a shell prompt, and when nothing blocks it: a `STOP` or `PAUSE` file, `logs/halted` (it needs a human: read the
reason inside), usage at the limit, or no work (`logs/done` holds the current commit: the project is finished; a
`change:` commit gives it work). After three starts in a row that died at once it waits for the next commit: run
`./loopkit/run.sh` in the loop window to see the error. Its state is in `logs/guard.json` and its window.

**The usage guard does nothing**
It needs a subscription plan (with an API key there are no usage windows: use `BUDGET_USD`). It also needs at least
one finished session in `logs/` to read usage from, and `TMUX_TARGET` must match your tmux session and window
(`loop:loop` by default) for `AUTO_RESUME`. If you run your tmux session on another server (`tmux -L name`), set
`TMUX_SOCKET=name`.

**The roadmap shows no ETA or a strange one**
It needs a few passing features to learn the pace, and gets better after about 30. Features must have the `[Block]`
prefix and ids starting with `F`.

**The demo stays on an old version**
Look at `<project>-demo/.demo/update.log`: a failing build keeps the previous version on purpose.

**The security review created features I disagree with**
The triage records why in `DECISIONS.md` ("Security review · round N"). Mark the feature `blocked` with a note
through `prompts/CHANGE.md`, or change the SPEC if the behaviour is intended; the next round reads `DECISIONS.md`.
To skip the review for a batch, `SECURITY_ROUNDS=0` in `loopkit.env`.

**The user test was skipped**
`usertest.env` needs `USERTEST_START` and `USERTEST_ZONES`; the copy must build, seed and answer on
`USERTEST_HEALTH` within two minutes. Details in `logs/usertest-*/`. Rounds are counted since the last `change:`
commit, so after `USERTEST_ROUNDS` rounds it stops testing until you make a change.

**Running the tests of the kit itself**
`tests/run-tests.sh` (needs bash, git, jq, python3, curl). It drives the real harness with a fake Claude, no network
and no cost.
