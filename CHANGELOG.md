# Changelog

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
