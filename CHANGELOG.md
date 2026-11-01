# Changelog

## Unreleased

- Worker and QA prompts: crash and rollback tests must use the real boundary (kill the process, roll back a real
  database transaction). An injected exception or a mocked transaction can pass while data is lost.

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
