We are going to plan a piece of software that an autonomous loop of agents will then build over days or weeks WITHOUT human intervention. Whatever is not defined now, they will decide on their own. Your job in this session is only to plan, not to build it.

Talk to me in the language I write to you in. The files you generate follow the project languages we agree on in the interview.

## Phase 0 — Existing code (skip it if the folder is empty)
If this folder already has code (an "adoption"), study it before asking anything: structure, stack, how to install, run and test it, what works today (run the tests), what is half done, conventions and obvious debt. Write a short summary of the current state. In the interview, ask only what the code cannot tell you. In phase 2, `SPEC.md` describes the target and respects what exists unless we agree to change it, and `features.json` contains only the remaining work (plus, as its first feature, making the existing test suite run green from `init.sh` if it does not already). Never plan a rewrite unless I ask for it.

## Phase 1 — Interview
Ask me questions in rounds of 3-5 (multiple choice whenever you can) until you have covered:
- Goal, users and main use cases
- Features: must have / nice to have / out of scope
- Stack (propose one if I have no preference and justify it in one line), database, auth
- Where it runs (local, Docker, cloud), ports, external services and credentials (whatever cannot be obtained without me is marked out of scope or mocked)
- UI: screens, style, references (or the interface it has: CLI, API, library…)
- Quality bar: tests, performance, security, accessibility
- Languages: of the product's UI and content, of the docs, and of code identifiers and comments
- What "done" means
Every question carries your bet for the answer and why: I react faster to a wrong bet than to a blank question. Challenge me when something is vague or contradictory; if I answer with textbook words ("scalable", "modern", "the usual"), ask me what I actually want.
When you can predict my answers to your next three questions, stop and write a summary to confirm line by line: goal, users, why now, how we will know it worked, main constraint, out of scope (mandatory) and the assumptions you are making. Do not move to phase 2 until I say "generate".

## Phase 2 — Generate these files
1. `SPEC.md`: vision, scope and out of scope, architecture, data model, folder structure, conventions (with a real code snippet that shows the style), allowed dependencies, screens/endpoints/commands, testable success criteria, boundaries (always / never), project languages and decisions already made. It must be enough for an engineer with no context to build the software.
2. `CLAUDE.md`: commands (install, run, test, lint, e2e), code conventions, project languages, repo rules. Short. Include these rules: `features.json` is managed by the harness; never touch `loopkit/`, `demo.env`, `usertest.env` or `loopkit.env`; never create or delete `STOP` or `PAUSE`; port 8090 belongs to the roadmap and the demo (`DEMO_PORT`) and user-test (`USERTEST_PORT`) ports are not used in tests either; if `docs/design/` exists, visual work reproduces it (read its README).
3. `features.json` with exactly this format:
   ```json
   {"features":[{"id":"F001","priority":1,"depends_on":[],"description":"...","steps":["..."],"verify":"shell command","passes":false,"attempts":0,"blocked":false,"notes":""}]}
   ```
   - `description` starts with its block in brackets (`[Base] Scaffolding…`, `[Profile] …`): the roadmap groups by it. Use few blocks (5-15) with short, stable names.
   - Between 30 and 300 features, each one implementable and verifiable in a single session (≈1-2 h of work). Size the plan to the budget: every feature costs one worker session plus one QA session.
   - F001 is the scaffolding: project created, it starts, an example test and the e2e tooling configured.
   - `verify` is a shell command the harness runs as is with `bash -c` from the repo root, with no agent around. Requirements:
     - Self-contained: it starts whatever it needs (e.g. Playwright's `webServer`) and leaves no processes behind.
     - Non-interactive, deterministic and under 15 minutes.
     - Exit code 0 only if the feature works; never "check that it looks fine". It must fail today: before the first worker of each feature the harness runs it, and one that already passes (it checks nothing) goes to the replanner.
     - It targets concrete tests of that feature (e.g. `npx playwright test e2e/login.spec.ts`, `pytest tests/test_login.py`), which the worker will write.
   - Logical order with `priority` and `depends_on` (no cycles, only existing ids). Include end-to-end tests of complete flows near the end.
   - Security by design. A loop builds exactly what the plan says, and projects with green tests have shipped every one of these, so write them into `SPEC.md` (boundaries) and into the features that touch them:
     - Anything published (the demo, the user-test copy, production) runs in production mode. Development conveniences (mail catchers, test or seed routes, simulators, debug endpoints, verbose errors, relaxed cookies) exist only behind an explicit flag, never because a mode variable was left unset, and are never reachable without a session.
     - No fixed credentials: seeds take passwords from the environment or generate random ones, printed once and saved to a file with mode 600; none ever ship in the client bundle.
     - Rate limits work behind a reverse proxy (configurable trusted hops) and also count per account, not only per IP; expensive endpoints (uploads, image processing, search) have limits.
     - No tokens, reset links, passwords or personal data in logs.
     - Every retention promise in the SPEC or the privacy text ("stories last 24 h", "no history", "deleting the account deletes everything", "only while visible") gets a feature that purges or stops collecting, with a test.
     - Features that expose anything derived from sensitive data (location, distances, presence, "last seen") include an anti-probing plan: the server does not trust client-supplied facts it cannot check (e.g. impossible jumps in position), obfuscation uses a server-side secret, and repeated requests do not reveal more than one does.
4. `init.sh`: idempotent, installs dependencies and leaves the environment ready to work and test (leaving no processes behind).
5. `.gitignore` for the stack (dependencies, builds, test reports) plus `logs/`, `STOP`, `PAUSE`, `loopkit.env`, `.demo/` and `__pycache__/`.
6. `PROGRESS.md` and `DECISIONS.md`, empty except for a title, and `LEARNINGS.md` from `loopkit/templates/LEARNINGS.md` (in adoption mode, seed it with the conventions, commands and gotchas you found in phase 0; at most 80 lines).
7. `demo.env` (if there is something to show): read by `loopkit/demo.sh`, which keeps a copy of the app always on the latest passing feature, so the owner can show it while the loop works. Shell variables:
   ```bash
   DEMO_PORT=3000                       # different from 8090 and from the test ports
   DEMO_INSTALL='npm ci --no-audit --no-fund'   # re-run when the lockfile changes (DEMO_INSTALL_PATHS for other files)
   DEMO_BUILD='npm run build'           # required
   DEMO_START='node dist/server.js'     # required; in the foreground, reads $PORT; demo data inside the folder (e.g. .demo/)
   DEMO_RESEED='rm -f .demo/demo.db && npm run seed'   # creates the demo data from scratch
   DEMO_RESEED_PATHS='^src/seed/'       # path regex: if a commit touches them, the data is recreated
   DEMO_LOGIN='demo@example.com · password in .demo/credentials.txt'   # shown when it starts; never a fixed password
   ```
   Environment variables it needs (production mode, demo database, demo mode, an explicit flag for any dev tool the demo needs) are exported in `demo.env` itself. Plan an early feature that makes the app showable with demo data (seed), so the demo is useful from the start.
8. `usertest.env` (if the app has a UI): read by `loopkit/run.sh` when the features run out, for the automatic user test (testers with a browser, one per zone, on an isolated copy, and a triage that turns their findings into features; see `loopkit/prompts/TESTER.md` and `TRIAGE.md`). The copy runs from the repo itself with its data in `$USERTEST_DATA`. Shell variables:
   ```bash
   USERTEST_PORT=3400                   # different from 8090, DEMO_PORT and the test ports
   USERTEST_HEALTH=/api/health          # path that answers 200 when the copy is ready
   USERTEST_BUILD='npm run build'
   USERTEST_SEED='DB_PATH="$USERTEST_DATA/app.db" npm run seed'     # test data from scratch, never the demo's
   USERTEST_START='NODE_ENV=production DB_PATH="$USERTEST_DATA/app.db" PORT="$USERTEST_PORT" exec node dist/server.js'   # in the foreground, in production mode like the real thing
   USERTEST_INFO='test accounts, dev mailbox, how to fake what headless lacks (GPS, payments…) and how to run Playwright'
   USERTEST_ZONES=(                     # one tester per zone, 3-5 without overlaps: "name|what to test (screens, SPEC sections, designs)"
     "accounts|sign-up, log-in, settings…"
     "core|the main feature…"
   )
   ```
   If something limits several testers at once (per-IP rate limits, unique accounts), plan for the demo or test mode to relax it through an explicit setting, not by running in development mode. The same copy is what the automatic security review reasons about: describe in `CLAUDE.md` how the demo and the user-test copy are started.

## Phase 3 — Visual design (if the product has a UI)
Visual work comes out better designed up front than improvised feature by feature. If you have tools to design visually (for example the Artifact tool with Claude Design's Design System and Design types):
1. Create the design system (brand, colour, type, base components) and the key screens with rich briefs (user, tone, references, empty and error states, mobile first), without asking the owner to do anything; show them the links.
2. Export what the loop needs to `docs/design/` (tokens, guide, screens) with `loopkit/templates/design-README.md` as `docs/design/README.md`, adapting its table and the colour-to-CSS-variable mapping.
3. Make the visual features cite their design file in `description`/`steps` ("reproduce `docs/design/screens/X.dc.html`").
Without such tools, write a concrete visual direction in `SPEC.md` (palette, type, density, references) instead of "modern and clean". Whatever is designed later goes in as a change (`loopkit/prompts/CHANGE.md`) before the loop reaches that feature.

## Final validation
Validate: `jq empty features.json`, unique ids and every `depends_on` exists; count the features and check that none is too big or has a vague verify. Run `bash init.sh` to check it works, and a few verifies (`bash -c "<verify>"`): they must fail now and not hang. On its first start the harness runs every pending verify and sends the ones that already pass to the replanner. Run `git init` (if needed) and commit "plan".
