# How it works

## The pieces

| Piece | What it is | Who writes it |
|---|---|---|
| `SPEC.md` | What to build: scope, architecture, conventions, boundaries, success criteria | The planner, with you |
| `CLAUDE.md` | Commands and repo rules every agent reads first | The planner |
| `features.json` | The plan: features with `priority`, `depends_on`, `verify`, `passes`, `attempts`, `blocked`, `notes` | The planner; afterwards **only the harness** (and the replanner/triage, validated) |
| `PROGRESS.md` | What each session did, skipped and recommends | Workers and the harness |
| `DECISIONS.md` | Ambiguities resolved, replans, user-test results, changes | Agents and you |
| `init.sh` | Idempotent setup (dependencies, browsers…) | The planner |
| `logs/` | Everything: `loop.log`, `notify.log`, one stream-json transcript per agent session, verify outputs, QA verdicts, user-test reports | The harness |
| `loopkit/` | The harness itself: never edited by the agents | `loopkit init/update` |

## One iteration

1. **Pick.** `run.sh` takes the pending, unblocked feature with the lowest `priority` whose dependencies all pass.
2. **Worker.** A fresh `claude -p` session gets `prompts/WORKER.md` plus that one feature. It reads the docs, runs
   `init.sh`, writes the tests first, implements, runs the `verify` itself, appends to `PROGRESS.md` and commits.
   If it touched `features.json`, the harness reverts it.
3. **Verify.** The harness runs the feature's `verify` with `bash -c` (with `VERIFY_TIMEOUT`). Non-zero exit = failed attempt.
4. **QA.** Another fresh session gets `prompts/QA.md`: it reads the diff, runs the whole test suite, tries the UI in a
   browser, checks the new tests would fail without the code, and looks for cheating. It writes `PASS` or `FAIL`
   (with reproduction steps) to `logs/qa-verdict.txt`; every other change it made is thrown away
   (`git reset --hard` + `git clean`).
5. **Score.** Only PASS from QA sets `passes: true`. A failure increments `attempts` and stores the reason in
   `notes`, which the next worker reads first. The harness commits `harness: Fxxx PASS|fail`.

## Safety nets

- **Replanning.** A feature failing `MAX_ATTEMPTS` times, `STALL_LIMIT` iterations without a new pass, or no feature
  with satisfied dependencies → the replanner (`prompts/REPLAN.md`) may split, reorder, fix a verify or block.
  It can only change `features.json` and `DECISIONS.md`; the harness reverts anything else and rejects a plan that
  deletes features, invents passes, breaks ids or points to missing dependencies. A feature still stuck after a
  replan is blocked by the harness. `MAX_REPLANS` replans in a row without progress halt the loop and notify you.
- **Regression sweeps.** Every `REGRESSION_EVERY` new passes, every passing feature's verify runs again; anything
  that broke goes back to pending with a note.
- **Transient failures** (usage limit, network, overload) are retried with backoff up to one hour, without counting
  as attempts. Timeouts and max-turns do count (they usually mean the feature is too big).
- **Never lose work.** Before every reset the harness checks the tree is committed; if git cannot commit (identity,
  full disk) it stops instead of wiping anything.
- **Single instance.** `logs/.lock` (flock) prevents two harnesses in one folder.
- **Budget.** With `BUDGET_USD`, it stops before starting an iteration once the reported cost reaches the cap.

## Pause, stop and changes

- `touch STOP`: the current iteration finishes and the harness exits. STOP stays, so nothing starts it again until
  someone runs `rm STOP`. The usage guard uses it too, and removes its own STOP once the loop has exited.
- **Auto-start.** The usage guard with `AUTO_RESUME=1` starts `run.sh` in the loop's tmux window whenever there is
  work and nothing stands in the way: the loop is not running; there is no `STOP`, `PAUSE` or `logs/halted`; usage
  leaves room; and the project either never finished or got new commits since its last DONE (the harness writes the
  commit it finished at to `logs/done`, so a `change:` commit means new work). The halts that need a human (replans
  without progress, git unable to commit, budget reached) write `logs/halted` with the reason; fix the cause and
  delete it (or run `./loopkit/run.sh` yourself). If the loop dies right after starting three times in a row, the
  guard stops trying until the next commit and notifies you. `loopkit/tmux.sh` creates the session (loop, roadmap,
  guard, demo) and a systemd user unit can run it at boot (`loopkit/templates/loopkit-tmux.service`).
- `touch PAUSE`: the current iteration finishes, `logs/paused` appears and the harness waits. `rm PAUSE` and it
  re-executes itself, so it picks up new versions of `run.sh`, the prompts and `features.json`, keeping its
  environment. `prompts/CHANGE.md` uses this so a change never needs a manual relaunch.
- A change ends with a `change: …` commit. That marks a new "batch" for the security review and the user test.

## The security review

Every feature passed its tests and a QA session, but nobody looked at the project as an attacker would. When no
feature is left, before the user test, the harness:

1. starts read-only reviewers in parallel (`prompts/SECURITY.md`; `SECURITY_REVIEWERS=2`: back end, and front end
   plus operations; `1` = one session for everything). They read the SPEC, the privacy promises and how the app is
   built and started, map the entry points and hunt for flaws that cross a real trust boundary, with the classes
   that slipped through in real projects first: development tools live in what gets published, fixed seed
   credentials, leaks through repeated or crafted requests, obfuscation without a secret, rate limits that do not
   work behind a proxy, secrets in logs, privacy promises without a purge. Each writes a report with `file:line`,
   attack steps and a fix to `logs/security-<iter>/`;
2. runs a triage (`prompts/SECURITY_TRIAGE.md`) that tries to refute every serious finding in the code, and turns
   the confirmed ones into `[Security N]` features whose verify reproduces the attack, ahead of anything pending,
   plus a full-regression feature. Low-risk notes and decisions that need you (a mail provider, a change to the
   privacy text) go to `DECISIONS.md`;
3. throws away any code change from reviewers or triage, validates the plan, commits `security: round N · …` and
   keeps looping.

Up to `SECURITY_ROUNDS` rounds per batch (default 1, counted since the last `change:` commit like the user test's);
a round with nothing to fix closes it. It reads code only: it does not attack a running app. For a test from
outside against a deployed copy, use a dedicated tool once the project is about to go public.

## The user test

When no feature is left (and the security review is done) and `usertest.env` exists, before declaring the project
done the harness:

1. builds the app and seeds a **separate** database in `logs/usertest-<iter>/data`, and starts it on `USERTEST_PORT`;
2. launches one tester per zone in parallel (`prompts/TESTER.md`): real browser (Playwright), phone and desktop
   sizes, screenshots compared with the design, every button followed to its final state, edge cases, two users at
   once; each writes a report;
3. runs a triage session (`prompts/TRIAGE.md`) that reproduces the serious bugs and turns them into
   `[User test N]` features whose verify reproduces the bug, plus a full-regression feature. Minor issues, product
   questions and things needing a new design go to `DECISIONS.md` for you;
4. throws away any code change from testers or triage, validates the plan, commits `usertest: round N · …` and
   keeps looping.

Up to `USERTEST_ROUNDS` rounds per batch (counted since the last `change:` commit); a round with nothing to fix
closes it. Each round costs roughly as much as 4-5 iterations.

## The roadmap

`./loopkit/roadmap.sh` serves a read-only page (stdlib Python, port 8090) built from `features.json`, `logs/` and
git: progress by block (the `[Block]` prefix of each description), a Gantt of real durations, the current feature
and its phase, recent decisions, the latest notes from `PROGRESS.md`, subscription usage and the guard's state.

The ETA learns from the project itself: it fits each feature's real cost (wall time between passes, so failures,
QA and sweeps are included) against the number of end-to-end tests its verify runs and its position, weighting
recent features more, then measures how far that same model was off over past windows of 20 features and applies
that as a safety margin and a range. It shows English or Spanish depending on the browser (or `?lang=`).

## The demo

`./loopkit/demo.sh` keeps a clone of the repo in `<project>-demo`, checks out the latest `harness: Fxxx PASS`
commit, builds and restarts it (`demo.env`). Work in progress is never shown; a failing build keeps the previous
version; demo data survives updates unless the seed changes.
