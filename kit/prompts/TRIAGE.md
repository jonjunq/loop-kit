You are the tech lead. The testers have just used the app like real people on an isolated copy and left their reports (paths at the end of this message). Turn them into work for the loop, **without building the app yourself**. No human is involved right now; the owner will read it later in `DECISIONS.md`.

1. Read `SPEC.md`, `CLAUDE.md`, `DECISIONS.md`, `features.json`, `docs/design/README.md` if it exists, and every report.
2. Merge and drop duplicates. Reproduce the blockers and majors yourself against the copy, which is still running at the URL at the end (scripts in the round's folder, never in the repo; do not start or stop servers). Drop whatever does not reproduce.
3. Classify each bug:
   - **Fix now**: blockers, majors and mediums that break the SPEC or the design.
   - **Note**: minor and cosmetic. They create no features; they go to the list in `DECISIONS.md`.
   - **For the owner**: product changes (the SPEC does not say, or something new would have to be decided) and whatever needs a new design. Do not create features for these unless the SPEC or the design already says how it must be.
4. In `features.json`, for the "fix now" items, create new features, grouping the fixes of a single screen (each feature 1-2 h of work):
   - ids after the current highest; `passes:false`, `attempts:0`, `blocked:false`, `notes:""`; `priority` above the current highest; a description prefixed with `[User test N] ` saying what happens today, what must happen and quoting the SPEC or the design.
   - Concrete `steps` and a self-contained shell `verify`: a test that **reproduces the bug** (fails today) plus that zone's existing tests, so nothing breaks.
   - If you create any, add a final `[User test N] Full regression` that depends on all of them, with the project's full-regression verify (the one of the latest regression feature, or the one `CLAUDE.md` gives).
   - Do not touch features that already pass and do not weaken any verify.
5. Append to `DECISIONS.md` an entry "User test · round N · date": zones tested, how many bugs came out, which features you created and why, the list of minor issues not fixed, what is left for the owner and what could not be tested.

If this is the last round (N equals the total) and only minor issues are left, create no features: the loop will finish and notify. You may only modify `features.json` and `DECISIONS.md`; the harness discards any other change and validates the JSON (unique ids, no feature deleted, dependencies exist, no new feature with `passes:true`). Do not commit: the harness does.
