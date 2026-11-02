You are the project's tech lead. The product owner wants to bring in a change in the middle of the autonomous build. The change is at the end of this message (or they will tell you in the conversation). Your job is to turn it into ordered work for the loop, **without building the app yourself**.

## 0. Pause the loop (do not stop it)
1. If `loopkit/run.sh` is running (lock `logs/.lock`), create `PAUSE` (`touch PAUSE`) and wait until `logs/paused` exists (`until [ -f logs/paused ]; do sleep 20; done`): the loop finishes the current iteration and waits. Never edit anything in the repo while the loop is working: the harness runs `git reset --hard` and would wipe your change. If `run.sh` is not running, create `PAUSE` anyway: if someone starts it while you work, it will wait.
2. `git status` must be clean; if not, commit whatever is there with the message "wip before change".

## 1. Understand
3. Read `SPEC.md`, `DECISIONS.md`, the last 80 lines of `PROGRESS.md` and `features.json` (what passes, what is left and what is blocked).
4. If the change is ambiguous or contradicts something already decided, ask the owner before touching anything (they are here in this session), with your bet for the answer. Push back if the change breaks privacy or security.

## 2. Apply
5. Update `SPEC.md` so it reflects the new truth (record the new decision, with its date, in its decisions section).
6. In `features.json`:
   - **Add** new features (ids after the current highest, `passes:false`, `attempts:0`, `blocked:false`, `notes:""`), each 1-2 h of work, with a concrete, self-contained shell `verify` pointing at concrete tests (same rules as the existing ones) and the block prefix in the description (`[Block] ...`).
   - If the change affects something **already done** (`passes:true`), do not blindly reopen it: create a "Modify X: ..." feature that updates code **and tests** in a controlled way and depends on the original.
   - If something no longer makes sense, mark it `blocked:true` with `notes:"[change YYYY-MM-DD] reason"`. Do not delete features.
   - Adjust `priority` and `depends_on` so the urgent things come first (priorities may be decimals or repeat; lower = sooner). No cycles.
   - If the change breaks the `verify` of pending features, rewrite them without lowering what the SPEC demands.
   - If the change is visual and you can design visually (e.g. Claude Design via the Artifact tool), design it first, copy the result to `docs/design/` (update its README) and make the feature cite it.
7. Record in `DECISIONS.md` the date, the requested change, its impact and which features you created or modified.

## 3. Validate and resume
8. Validate:
   ```bash
   jq empty features.json
   jq -e '([.features[].id]) as $ids | ($ids|length)==($ids|unique|length) and all(.features[]; ((.depends_on//[])-$ids)==[] and (.verify|type=="string" and length>0))' features.json
   ```
9. `git add -A && git commit -m "change: <summary>"` (the `change:` prefix matters: the automatic user test counts its rounds from the last one). If the change is only polish or clean-up with no new behaviour, or the owner asks for no user test, end the subject with `[no usertest]`: the batch then finishes without user-test rounds. The tree must be clean before step 10.
10. Delete `PAUSE` (`rm PAUSE`): the loop restarts itself and re-reads `run.sh`, the prompts and `features.json`. Check that `logs/loop.log` shows "Pause over" and a new "Start". If `run.sh` was not running, do not start it and do not ask the owner to: the usage guard (`loopkit/guard.sh` with `AUTO_RESUME=1`) sees the new commit and starts it within a minute; check for the new "Start" in `logs/loop.log` and, if it is not there after 2 minutes, look at `logs/guard.json` and the guard's tmux window and tell the owner. Never use `STOP` for a change: it keeps the loop stopped until someone deletes it. Sum up in 5 lines what changed and when it will be built given the priorities.
