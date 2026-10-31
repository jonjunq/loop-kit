# Case study: a social PWA in 2.5 days

The project that shaped loop-kit: a mobile-first progressive web app (social features: profiles, posts, stories,
real-time messaging, themes, eight languages, an admin panel) meant as a working prototype. TypeScript
monorepo (Fastify + SQLite/Drizzle API, React/Vite front end), Vitest and Playwright.

## Timeline

- **Planning:** one interactive session (interview + generation) produced a 388-line SPEC and 117 features.
- **Build:** about 58 hours of wall time from the first feature to feature 132, including usage-window pauses,
  stops for owner changes and the owner's manual user test.
- **Owner changes:** a few, through `CHANGE.md`: a navigation restyle and a design system (two new features), plus
  design references and reordering. After the PAUSE mechanism existed, none required relaunching the loop by hand.

## Numbers

| | |
|---|---|
| Features | 132 passing, 0 blocked |
| Iterations | 141 |
| Agent sessions | 343: 171 worker (median 8 min), 172 QA (median 3 min) |
| Cost | $372 API-equivalent (Opus everywhere, on a Max subscription), about $2.80 per feature |
| Failed attempts | 11: 10 caught by QA after the verify had passed, 1 verify failure |
| Replans | 0 |
| Regression sweeps | 10, one regression caught and fixed |
| Code | about 146,000 lines including tests (lockfiles and design files excluded) |

## What each safety net caught

- **QA after a passing verify** caught 10 real problems the feature's own tests did not: a type-check broken
  elsewhere, a seed data file silently excluded by `.gitignore`, a feed going stale after in-app navigation, a new
  floating bar covering a chat's input, a flaky end-to-end test (failing half the time), a layout algorithm that only
  worked for the exact cases its test used (caught twice), a size budget missed and admitted in the notes, and a
  change that broke nine end-to-end flows outside its verify. Without it, all of them would have been marked done.
- **Regression sweeps** caught one feature broken by a later one.
- **The manual user test** after the plan was complete (four testers with a browser, one per area) found 12 groups
  of bugs the loop had considered done: a report dialog opening behind the viewer it belonged to, no compression and
  a single huge JS bundle on first visit, form rows overflowing at phone width, a wrong default on an onboarding
  toggle, a flow offering an action again after it had been declined, a placeholder instead of a real 404, a language
  choice lost after logging in, an admin table unusable on a phone and double submissions, list rows and cards not
  matching the design, and per-IP limits that blocked a group trying the demo together. They became 12 fix features
  plus a full regression, and the loop fixed them. That experience is why the user test now runs automatically at the end of every batch.

## Prompt experiment

Midway, the worker prompt gained the "Minimal code" rules and tests-first. Comparing 21 features after the change
with the 20 before:

| | Before | After |
|---|---|---|
| Lines added per feature (median) | 960 | 587 (−39 %) |
| Failed attempts per feature | 0.10 | 0.05 (−52 %) |
| Cost per worker session | $1.66 | $1.92 (+16 %) |
| Duration per worker session | 7.0 min | 16.9 min (×2.4) |

Less code and fewer failures, at the price of slower sessions (writing tests first and checking them takes time).
The features after the change were also later in the project and heavier, so take the numbers as a direction, not a
measurement.

## Lessons now built into the kit

- Design screens before the loop builds them; feature-by-feature improvisation looked generic.
- Keep a demo on the latest passing commit, never on the working tree: people testing the demo saw a consistent app
  while the loop kept resetting its repo.
- Give the user test its own copy and its own data; a shared demo database and per-IP rate limits got in the way.
- Pausing must not require relaunching by hand: changes happen at any hour.
- The ETA must learn from the project's real cost per feature (failures, QA and sweeps included), or it drifts later
  every hour as features grow.
