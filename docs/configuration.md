# Configuration

## Where settings come from

1. Environment variables (`MODEL=sonnet ./loopkit/run.sh`)
2. `loopkit.env` in the project root (plain shell, git-ignored because it may hold tokens; `loopkit init` creates it
   from `loopkit/templates/loopkit.env.example`)
3. The defaults below

Prefer `loopkit.env`: the usage guard relaunches the loop with a plain `./loopkit/run.sh`, and a PAUSE restart keeps
the environment, but a fresh shell does not.

## Harness (`run.sh`)

| Setting | Default | What it does |
|---|---|---|
| `MODEL` | Claude Code's default | Worker model (`opus`, `sonnet`, `haiku` or a full model id) |
| `QA_MODEL` | `MODEL` | QA auditor model. `sonnet` saves quota; a weaker QA lets more through |
| `REPLAN_MODEL` | `MODEL` | Replanner model |
| `PERMS` | `--permission-mode auto` | Permission flags for every agent session. In a disposable sandbox: `--dangerously-skip-permissions` (see [isolation](isolation.md)) |
| `BUDGET_USD` | none | Stop before the next iteration once the sessions' reported cost reaches this |
| `VERIFY_TIMEOUT` | `20m` | Cap per verify command (raise it when e2e suites grow; 45m is common late in a web project) |
| `ITER_TIMEOUT` | `3h` | Cap per agent session |
| `MAX_TURNS` | `300` | Turns cap per agent session |
| `MAX_ATTEMPTS` | `3` | Failed attempts before a feature triggers a replan |
| `STALL_LIMIT` | `6` | Iterations without a new pass before a replan |
| `MAX_REPLANS` | `5` | Replans in a row without progress before halting |
| `REGRESSION_EVERY` | `10` | Re-run every passing verify after N new passes (`0` = never) |
| `MAX_ITER` | `10000` | Iterations per launch |
| `USERTEST_ROUNDS` | `2` | User-test rounds per batch when the features run out (`0` = never) |
| `USERTEST_MODEL` | `QA_MODEL` | Testers and triage model |
| `USERTEST_TIMEOUT` | `90m` | Cap per tester |
| `NTFY_TOPIC`, `NTFY_SERVER` | none, `https://ntfy.sh` | Push notifications through ntfy |
| `NOTIFY_CMD` | none | A script that gets each notification as its argument, or an inline command using `"$1"` ([notifications](notifications.md)) |
| `CLAUDE_BIN` | `claude` | Claude Code binary (the tests point it at a fake) |

## Usage guard (`guard.sh`)

Environment variables only (it is a separate process in its own tmux window; `loopkit/tmux.sh` starts it with
`AUTO_RESUME=1`). It finds the project from its own location, or from `ROADMAP_ROOT`.

| Setting | Default | What it does |
|---|---|---|
| `GUARD_LIMIT` | `80` | Stop the loop when 5-hour usage + one iteration's typical cost reaches this % |
| `AUTO_RESUME` | `0` | `1` = start the loop whenever there is work (pending features, or commits since the last DONE) and again when the usage window renews |
| `TMUX_TARGET` | `loop:loop` | tmux pane where the loop runs (session:window); it must be idle at a shell prompt |
| `TMUX_SOCKET` | none | tmux server name (`tmux -L`), if you run the session on a non-default server |
| `RESUME_CMD` | `./loopkit/run.sh` | Command typed into that pane (after `cd` to the project) to start the loop |
| `GUARD_INTERVAL` | `20` | Seconds between checks |

## Roadmap (`roadmap.sh`)

| Setting | Default | What it does |
|---|---|---|
| `ROADMAP_PORT` | `8090` | Port |
| `ROADMAP_HOST` | `0.0.0.0` | Bind address (`127.0.0.1` to keep it local and use an SSH tunnel) |
| `PROJECT_NAME` | folder name | Name in the header |
| `ROADMAP_USER` | none | Name in the greeting |
| `ROADMAP_ROOT` | the project | Project folder to read (to view another project) |

The roadmap is read-only and has no authentication. Do not expose it to the internet without a reverse proxy with auth.

## Demo (`demo.env`, read by `demo.sh`)

| Setting | Required | What it does |
|---|---|---|
| `DEMO_BUILD` | yes | Build command |
| `DEMO_START` | yes | Start command, in the foreground, reading `$PORT` |
| `DEMO_PORT` | no (3000) | Port |
| `DEMO_INSTALL` | no | Dependency install, re-run when a lockfile changes |
| `DEMO_INSTALL_PATHS` | no | Regex of files that trigger `DEMO_INSTALL` (default: common lockfiles) |
| `DEMO_RESEED` | no | Creates the demo data from scratch (first start, and when the seed changes) |
| `DEMO_RESEED_PATHS` | no | Regex of paths that trigger a reseed |
| `DEMO_LOGIN` | no | Credentials printed at start |
| `DEMO_DIR` | no | Clone location (default `<project>-demo`) |
| `INTERVAL` (env) | no (60) | Seconds between checks for a new passing commit |

## User test (`usertest.env`, read by `run.sh`)

| Setting | Required | What it does |
|---|---|---|
| `USERTEST_START` | yes | Starts the isolated copy, in the foreground, on `$USERTEST_PORT`, with data under `$USERTEST_DATA` |
| `USERTEST_ZONES` | yes | Bash array, one tester per entry: `"name|what to test"` |
| `USERTEST_PORT` | no (3400) | Port of the copy |
| `USERTEST_HEALTH` | no (`/`) | Path that answers 200 when the copy is ready |
| `USERTEST_BUILD` | no | Build command |
| `USERTEST_SEED` | no | Seeds the copy's own data under `$USERTEST_DATA` |
| `USERTEST_INFO` | no | Accounts, dev mailbox, how to fake GPS/payments, how to run Playwright: passed to every tester |

## features.json

```json
{"features": [{
  "id": "F001", "priority": 1, "depends_on": [],
  "description": "[Base] Scaffolding: …",
  "steps": ["…"],
  "verify": "npm test -- base && npx playwright test e2e/smoke.spec.ts",
  "passes": false, "attempts": 0, "blocked": false, "notes": ""
}]}
```

Ids must be unique and start with `F` (the roadmap and the demo look for `Fxxx`). Lower `priority` goes first;
decimals and repeats are fine. `verify` is run from the repo root with `bash -c`, must be self-contained, non-interactive,
deterministic, under `VERIFY_TIMEOUT`, and exit 0 only when the feature works.

## Files the harness creates

`logs/loop.log` (timeline), `logs/notify.log` (notifications), `logs/iter-NNNNN-<role>.jsonl|.err` (full transcript of
each agent session), `logs/verify-<id>.log`, `logs/qa-verdict.txt`, `logs/usertest-NNNNN/` (copy data, server log,
reports), `logs/guard.json`, `logs/.lock`, `logs/done` (commit of the last DONE), `logs/halted` (why it stopped
needing a human; delete it to let the guard start the loop again). Commit messages: `harness: …`, `replan: …`, `usertest: round …`, plus the
workers' `Fxxx: …` and your `change: …`.
