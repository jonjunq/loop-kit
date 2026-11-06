# Changelog

## 1.2.0 — 2026-11-06

- **The harness protects itself.** Whatever the worker changes in `loopkit/` (prompts, scripts), `demo.env` or
  `usertest.env` is reverted after its session ("Worker touched the harness -> reverted"), and `loopkit.env`, which is
  git-ignored and so survived every reset, is restored after any agent's session from a copy taken at start. Your
  own changes still go in through `PAUSE` (`prompts/CHANGE.md`): the copy is taken again when the loop restarts.
- **Red flags for the QA.** The harness reads the worker's diff and hands the QA what looks like a weakened check:
  test files deleted, `skip`/`only`/`xit`/`@skip`/`todo` added, fewer assertions or test cases, changes to the files
  the verify runs or to the test runner's configuration. The QA checks each one; a flag is not a verdict.
- **Red before starting.** Before the first worker of a feature, the harness runs its verify; if it already passes
  (an empty or weak verify, or work an earlier feature already did) no worker starts and the replanner gets it with
  the note "verify already passes before any work". Once per verify, never on retries, not for "Full regression"
  gates. On the first start of a plan every pending verify is checked and the green ones go to one replan.
- **Durable learnings.** `LEARNINGS.md` (template in `templates/`, created by the planner or by the harness if
  missing): conventions, commands and gotchas every worker reads first and adds to only with general, reusable
  lessons, 80 lines at most (the harness asks the next worker to condense it when it grows). Workers still read only
  the last 60 lines of `PROGRESS.md`. After the "Codebase Patterns" section of snarktank/ralph.
- **Usage limits: wait for the reset, then resume.** The limit is detected from Claude Code's `rate_limit_event`
  (`status: rejected`) and its `usage_limit_reached` error, with the message as a fallback ("usage limit
  reached|<epoch>", "resets 3pm (Europe/Madrid)", "try again in 2h"); the harness notifies the resume time, sleeps
  until the reset plus two minutes (`logs/waiting`, so the usage guard does not put a STOP that would lose the
  session) and resumes the same session with `claude --resume <session_id>` when it had started working, or starts a
  new one if the resume fails. Network failures resume the same way. `STOP`/`PAUSE` end the wait without counting an
  attempt.
- **Hung sessions are killed.** New setting `HANG_SECONDS` (default `VERIFY_TIMEOUT` + 10 min, `0` = off): a session
  whose transcript stops growing that long is killed and counts as a failed attempt ("hung: no output for N s").
- **No leftover processes.** Sessions and verifies run with a token in their environment, so whatever they start,
  detached dev servers included, is found and killed when they end. They also no longer inherit the loop's lock
  (a leftover server holding it made the guard think the loop was still running).
- A transcript is now read only from where the current session started: a retry no longer sees the previous
  attempt's result.
- README: credits Anthropic's "Effective harnesses for long-running agents" and cites arXiv:2607.25152 on
  self-evaluating loops.
- Fix: `[no usertest]` was ignored in projects with a long history (the batch got a user test anyway). With
  `set -o pipefail`, `git log | grep -m1 … | grep -q` failed with SIGPIPE when grep stopped reading early, and the `!`
  turned that into the opposite answer. The checks in `usertest_pending`, `security_pending` and the transient-error
  detection now compare in a variable. Tests run on a 3,000-commit history.
- README diagram redrawn with [Archify](https://github.com/tt-a1i/archify) instead of Mermaid: light and dark SVG,
  plus an interactive HTML version ([online](https://jonjunq.github.io/loop-kit/diagrams/how-it-works.html), GitHub Pages from `docs/`) and its source in
  [docs/diagrams/](docs/diagrams/).
- Worker and QA prompts: crash and rollback tests must use the real boundary (kill the process, roll back a real
  database transaction). An injected exception or a mocked transaction can pass while data is lost.
- `[no usertest]` at the end of a `change:` commit subject closes the batch without user-test rounds, for polish or
  clean-up batches (each round adds fix features and makes the batch longer).
- QA does not run the whole suite again when the feature's `verify` already did; with a partial `verify` it runs only
  the tests for what the diff touches.

## 1.1.0 — 2026-10-31

- Automatic security review when the features run out, before the user test: read-only reviewers in parallel
  (`prompts/SECURITY.md`) look for exploitable flaws, a triage (`prompts/SECURITY_TRIAGE.md`) refutes what it can and
  turns the rest into `[Security N]` features ahead of pending work. Settings `SECURITY_ROUNDS` (default 1),
  `SECURITY_MODEL`, `SECURITY_REVIEWERS`, `SECURITY_TIMEOUT`; reports in `logs/security-NNNNN/`; commits
  `security: round N · …`. The roadmap shows security reviews and user tests in the activity feed and the Gantt.
- Planning rules against the security bugs a real project shipped with green tests: published copies run in
  production mode, no fixed seed credentials, development tools only behind an explicit flag, proxy-aware and
  per-account rate limits, no secrets in logs, a purge feature for every retention promise, an anti-probing plan for
  location and other sensitive data.

## 1.0.0 — first public release

- Harness (`run.sh`): harness-owned state, verify run by the harness, independent QA with discarded changes,
  validated replanner, blocking of features a replan cannot fix, halt after unproductive replans, regression sweeps,
  transient-failure backoff, never resets uncommitted work, single-instance lock, continuous iteration numbering.
- PAUSE that restarts itself (changes never need a manual relaunch); STOP that stays until removed; `BUDGET_USD`
  cap; `logs/done` and `logs/halted` markers.
- Automatic user test when the features run out: isolated copy, one browser tester per zone, triage into features,
  rounds per batch of changes.
- Prompts: planning interview with bets and adoption mode, worker with "minimal code" and tests first, sceptical QA,
  replanner, change, tester, triage and manual user test.
- Live roadmap (English/Spanish) with an ETA that learns from the project's real cost per feature.
- Usage guard for subscription plans that also starts the loop whenever there is work (pending features, a new
  commit after it finished, a renewed usage window) and gives up after three crashed starts; `tmux.sh` and a systemd
  user unit to bring the session back after a reboot; always-up-to-date demo; notifications via ntfy or any command;
  remote notification watcher; Docker runner; `loopkit init/update/doctor`; end-to-end tests with a fake Claude.
