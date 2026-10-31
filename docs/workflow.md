# Workflow guide

## 1. Plan well (it decides most of the outcome)

`claude --model opus` in the project, then `Read loopkit/prompts/PLAN.md and follow it.`

- The planner interviews you in rounds of 3-5 questions, each with its bet for the answer. Correct the bets; when
  you answer with vague words ("modern", "scalable") it will ask what you actually mean.
- It stops when it can predict your next answers and shows a summary: goal, users, why now, how you will know it
  worked, main constraint, **out of scope**, assumptions. Fix it line by line. Then say `generate`.
- Review before launching:
  - `SPEC.md`: would an engineer with no context build what you want from it? Are the boundaries (always/never) right?
  - `features.json`: 30-300 features of 1-2 h each, grouped in 5-15 `[Blocks]`, each with a concrete `verify`.
    Try a few by hand: they must fail now and must not hang.
  - The project languages (UI, docs, code) are written down in `SPEC.md`/`CLAUDE.md`.
- Whatever you leave undefined, the agents will decide for you. That is fine for details, not for the product.

## 2. Design first (if there is a UI)

Visual quality comes out much better when screens are designed before the loop builds them than when each feature
improvises its look. In phase 3 the planner, if it has visual design tools (e.g. Claude Design through the Artifact
tool), creates a design system and the key screens, exports them to `docs/design/` with a README explaining how to
read them, and makes the visual features cite them. Without those tools it writes a concrete visual direction into
the SPEC. Any design file you produce elsewhere (Figma exports, HTML mock-ups) works too: put it in `docs/design/`
and describe it in its README.

## 3. Run

See the README quick start: `./loopkit/tmux.sh` creates a tmux session with the loop, the roadmap, the guard (which
starts the loop itself whenever there is work) and the demo if `demo.env` exists. Then leave it alone; the roadmap
and the notifications tell you what is going on. Nobody needs to launch `run.sh` by hand: not you, not Claude.

What to look at now and then: `DECISIONS.md` (what the agents decided on their own), the QA notes in `PROGRESS.md`,
and blocked features in the roadmap.

## 4. Changes mid-build

Open `claude` in the project and say: `Read loopkit/prompts/CHANGE.md and apply this change: …`

It pauses the loop at the end of the current iteration, asks you about anything ambiguous, updates the SPEC, adds or
modifies features (never silently reopening finished ones), records the decision, commits `change: …` and lifts the
pause. The loop restarts itself with the new plan; if it had already finished, the guard sees the new commit and
starts it. Never edit the repo by hand while the loop is working: the
harness resets the tree after each QA and replan and would wipe your edits.

To change the harness itself (a prompt, `run.sh`): same thing, `touch PAUSE`, wait for `logs/paused`, edit, `rm PAUSE`.

## 5. The demo

If the planner wrote `demo.env`, `./loopkit/demo.sh` keeps `<project>-demo` on the latest passing feature at
`http://<host>:3000`. Good for showing progress to others: it never shows half-done work. If a change touches the
seed data, the demo data is recreated (tell your testers).

## 6. User test

With `usertest.env`, the harness runs an automatic user test when the features run out (see
[how it works](how-it-works.md#the-user-test)), turns real bugs into features and keeps going. Read the
"User test" entries in `DECISIONS.md` afterwards: minor issues and product questions wait there for you.

To run it with you present (to decide what gets fixed, or redesign something), stop or pause the loop and tell
`claude`: `Read loopkit/prompts/USERTEST.md and follow it.`

## 7. Adopting an existing project

`loopkit init` on a folder with code, then plan as usual. The planner first studies the code (structure, stack, how
to build and test it, what works, what is half done), asks only what the code cannot tell, and plans only the
remaining work, starting by making the existing test suite pass from `init.sh`. It never plans a rewrite unless you
ask. The loop works best when the existing project has (or gets, in its first features) tests it can trust.

## When it finishes

You get a notification. Check `DECISIONS.md` for what is left for you, run the demo, and if you want more, plan the
next batch with `CHANGE.md` (it adds features to the same plan): the guard starts the loop on its own.
