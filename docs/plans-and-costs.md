# Plans and costs

A long build is token-hungry. Every feature is at least two full agent sessions (worker + QA), each of which reads
the docs, runs the tests and, late in a web project, a browser suite. Plan for it.

## What it cost in practice

Measured on the case-study project (132 features, Opus for every role, on a Max subscription, where the cost is the
API-equivalent figure Claude Code reports):

| | Median per session | Total |
|---|---|---|
| Worker | about 8 min | 171 sessions, $284 |
| QA | about 3 min | 172 sessions, $88 |
| Whole project | about $2.80 per feature | 343 sessions, $372 |

Features get bigger and slower as the project grows (more tests to run). The roadmap's ETA accounts for that.

## Subscription (Pro, Max, Team, Enterprise)

- Usage is metered in rolling windows (5 hours and 7 days). When a window is exhausted, sessions fail with a usage
  limit; the harness treats it as transient and waits (backoff up to 1 h) without counting attempts.
- **The usage guard** (`./loopkit/guard.sh`, in its own tmux window) reads the usage Claude Code reports in each
  session's log, and puts `STOP` when 5-hour usage plus one typical iteration would cross `GUARD_LIMIT` (80 % by
  default), so you keep the rest of the window for your own work, and removes that STOP once the loop has exited.
  With `AUTO_RESUME=1` it starts the loop again when the window renews (and, in general, whenever there is work and
  usage leaves room). Remove the STOP by hand while it is stopping and it backs off until the next window.
- The roadmap shows both windows and when they renew.
- Bigger plans simply mean fewer pauses. A Pro plan works, just slowly: use `MODEL=sonnet`, keep features small,
  and expect the loop to spend most of each day waiting.

## API key (pay as you go)

- Set `ANTHROPIC_API_KEY` (or log Claude Code in with a Console account). There are no usage windows, so the guard
  has nothing to do: use `BUDGET_USD` in `loopkit.env` instead. The harness stops before starting an iteration once
  the sessions' reported cost reaches it and writes `logs/halted`; raise it and delete `logs/halted` (or run
  `./loopkit/run.sh`) to continue. The guard's auto-start works with an API key too: run it with `AUTO_RESUME=1`.
- The reported cost is Claude Code's own estimate per session. Keep an eye on the Console too, and set a spend limit
  there as a hard backstop.
- Cloud providers (Amazon Bedrock, Google Vertex AI, Microsoft Foundry) work the same way: configure Claude Code
  for them as their docs say; the harness only calls the `claude` CLI.

## Choosing models

| Role | Suggestion |
|---|---|
| Planning (interactive) | Your best model. It decides most of the outcome |
| Worker (`MODEL`) | Your best coding model. A weaker worker fails more and each failure costs a full retry |
| QA (`QA_MODEL`) | Same as the worker if you can. `sonnet` is a reasonable saving; a weak QA lets cheating through |
| Replanner (`REPLAN_MODEL`) | Same as the worker; it runs rarely |
| Testers and triage (`USERTEST_MODEL`) | Defaults to `QA_MODEL` |

Do not switch models in the middle of a project without reason: the ETA and the failure rate are calibrated on what
ran before.

## Ways to spend less

- Fewer, well-sized features (1-2 h of work each). Tiny features pay the fixed cost of reading docs and running tests
  many times; huge ones time out and retry.
- Fast, targeted `verify` commands; save the full suite for a few regression features.
- `REGRESSION_EVERY=20` or `0` if your verifies are slow and you trust the QA's full-suite run.
- `USERTEST_ROUNDS=1` or `0`.
- A cheaper `QA_MODEL`.
