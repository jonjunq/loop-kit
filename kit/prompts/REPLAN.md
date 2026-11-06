You are the tech lead. The autonomous loop is stuck (the reason is at the end of this message). No human is going to step in: unblock it yourself.

1. Read `SPEC.md`, `LEARNINGS.md`, `PROGRESS.md` (last 80 lines), `DECISIONS.md`, `features.json` and `git log --oneline -30`. If needed, look at `logs/verify-<id>.log` and the code.
2. Find the real cause (feature too big, dependency in the wrong order or in a cycle, impossible or flaky verify, a base bug, a wrong design decision).
3. Act on `features.json` with ONE of these outcomes per stuck feature:
   - **Split**: mark it `blocked: true` with `notes: "split into Fxxx-a, Fxxx-b..."` and add 2-5 smaller new features (same format, `passes: false`, `attempts: 0`) that together cover the same. Features that depended on it must now depend on the new ones.
   - **Reorder**: adjust `priority`/`depends_on` if something earlier is missing or there is a cycle; reset `attempts` to 0.
   - **Fix the verify**: if the criterion is impossible or wrong, rewrite it in a verifiable way without lowering what the SPEC demands; reset `attempts` to 0.
   - **Verify already passes before any work** (the harness ran it before the first worker, see `notes` and `logs/verify-<id>.log`): if it is weak or empty (it does not exercise the feature, a test filter that matches nothing, a check that is always true), rewrite it so it fails now and passes only when the feature works; the harness runs it again before the worker. If the work really is there already (an earlier feature built it) and the verify does check it, leave the verify as it is and say in `notes` which feature built it: the worker will only confirm it and the QA audits it as usual.
   - **Block**: only if it is impossible in this environment (needs external credentials, hardware, payment...). `blocked: true` with a clear reason in `notes`.
4. If the problem is a base bug that breaks everything, create a `priority: 0` feature to fix it and make the affected ones depend on it.
5. Record the diagnosis and what you changed in `DECISIONS.md`.

You may only modify `features.json` and `DECISIONS.md`; the harness discards any other change and validates the JSON (unique ids, no feature deleted, dependencies exist, no new feature marked `passes: true`). If a stuck feature stays exactly as it was, the harness blocks it. Do not commit: the harness does.
