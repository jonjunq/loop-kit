You are the tech lead. Security reviewers have just read the project as attackers and left their reports (paths at the end of this message). Turn what is real into work for the loop, **without building anything yourself**. No human is involved right now; the owner will read it later in `DECISIONS.md`.

1. Read `SPEC.md`, `CLAUDE.md`, `DECISIONS.md`, `features.json` and every report.
2. Merge duplicates (two reviewers often find the same root cause from different sides). For every critical, high and medium finding, **try to refute it**: re-read the cited code yourself, follow the path from the entry point through middleware and hooks, and look for whatever might already block it. Drop what you can refute or cannot confirm in the code, and say so in `DECISIONS.md`.
3. Classify what is left:
   - **Fix now**: critical, high and medium findings that are exploitable, and anything that breaks a promise the SPEC or the privacy text makes to users.
   - **Note**: low-risk findings and hardening ideas. They create no features; they go to the list in `DECISIONS.md`.
   - **For the owner**: what needs a product or operations decision (a real mail provider, changing what the privacy text promises, putting something behind a login, a paid service). Do not create features for these.
4. In `features.json`, for the "fix now" items, create new features grouped by root cause (each feature 1-2 h of work):
   - ids after the current highest; `passes:false`, `attempts:0`, `blocked:false`, `notes:""`; `priority` below every pending feature's (security goes first), or above the current highest if nothing is pending; a description prefixed with `[Security N] ` saying what an attacker can do today, quoting the file and lines, and what must hold after the fix.
   - Concrete `steps` and a self-contained shell `verify`: a test that **reproduces the attack** (fails today: the forbidden request succeeds, the secret leaks, the probe distinguishes) plus that area's existing tests, so nothing breaks. If the fix changes how the app is started (production mode, flags, credentials), the feature also updates the demo and user-test start commands documented in `CLAUDE.md`, and its verify runs them.
   - If you create any, add a final `[Security N] Full regression` that depends on all of them, with the project's full-regression verify (the one of the latest regression feature, or the one `CLAUDE.md` gives).
   - Do not touch features that already pass and do not weaken any verify.
5. Append to `DECISIONS.md` an entry "Security review · round N · date": areas reviewed, how many findings came out and how many you confirmed, which features you created and why, what you dropped, the low-risk notes, and what is left for the owner.

If nothing exploitable is left, create no features: the loop will continue to the user test or finish. You may only modify `features.json` and `DECISIONS.md`; the harness discards any other change and validates the JSON (unique ids, no feature deleted, dependencies exist, no new feature with `passes:true`). Do not commit: the harness does.
