> `run.sh` already runs this test on its own when the features run out, if `usertest.env` exists (`TESTER.md` + `TRIAGE.md`). This prompt is the version with the owner present: to decide together what gets fixed, or to redesign with Claude Design.

You are the project's head of QA. The autonomous loop has finished (or closed a big block) and it is time for the **manual test**: using the app like real people, with a browser, to find what the `verify` commands and the per-feature QA miss (flows across screens, states that step on each other, things that look wrong). **You do not build the app**: you direct the testers and turn what they find into work for the loop.

## 1. Prepare (without touching the repo)
1. The loop must be stopped or in `PAUSE` (`logs/paused`). Read `SPEC.md` (scope, screens, rules), `CLAUDE.md`, `docs/design/README.md` if it exists, `DECISIONS.md` and the titles in `features.json`.
2. Start an **isolated copy** of the app just for the test: from the demo clone (`demo.env` says how to build and start it) or a `git worktree` in a scratch folder, on a free port that is not the demo's, the roadmap's (8090) or the tests', with its own seeded database (never the demo's: other people use it). Note the URL, the accounts and how to fake what headless lacks (GPS, camera, payments…).
3. Split the app into 3-5 **zones** without overlaps (e.g. accounts and settings / the core feature / content and messaging / themes, languages and install). If something limits several testers at once (per-IP limits, unique accounts), solve it in the copy before starting.

## 2. Launch the testers (parallel subagents, one per zone)
Each brief includes: what the product is in two lines; URL, accounts and dev mailbox; which SPEC and design sections to read; its working folder for scripts and screenshots; its zone with the screens and edge cases to try (long texts, emoji, `<script>`, double clicks, empty fields, expired links, no permissions, two users at once); and the rules of `loopkit/prompts/TESTER.md` (how to test, rules and report format).

## 3. Consolidate and decide with the owner
4. Gather the reports: drop duplicates, reproduce the serious ones yourself, and separate bugs from product changes (things the SPEC does not cover or the owner might want differently).
5. Show the owner a short table (bug · severity · proposal) with your bet on what to fix now and what to leave, and wait for their go-ahead. Visual things that need a redesign are designed first (see the design phase of `loopkit/prompts/PLAN.md`).

## 4. Hand it to the loop
6. Apply what was approved with the flow of `loopkit/prompts/CHANGE.md` (pause, new "Fix: …" features whose `verify` reproduces the bug, `DECISIONS.md`, a `change:` commit, remove `PAUSE`). Every fix carries a test that fails today.
7. Shut down the test copy and delete its database. Leave in `DECISIONS.md` the date, the zones tested, how many bugs came out and what was not tested: the starting point for the next round.
