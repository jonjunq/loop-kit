#!/usr/bin/env python3
"""Usage guard and starter: stops the loop (touch STOP) before the 5-hour usage window reaches GUARD_LIMIT % and,
with AUTO_RESUME=1, starts it whenever there is work, so nobody has to launch run.sh by hand.

Usage limits only exist on Claude subscription plans (Pro, Max, Team...), which report their usage windows; with an
API key that part just idles (use BUDGET_USD in run.sh instead), while auto-start still works. STOP is honoured when
the next iteration starts, so it is set when usage + the cost of one iteration reaches the limit: the current feature
finishes and the loop stays below. Leaving the rest of the window free is the point: you keep some for your own work.
Once the loop has exited, the guard removes its own STOP. If you remove STOP by hand before that, it does not set it
again until the next window. If the limit is hit anyway, run.sh waits for the reset by itself (logs/waiting) and then
resumes the interrupted session, so the guard does not stop it meanwhile: a STOP would lose that session.

With AUTO_RESUME=1 it starts run.sh in the tmux pane TMUX_TARGET (if the pane is idle at a shell prompt) when: the loop
is not running, there is no STOP, PAUSE or logs/halted (stopped because it needs a human), usage leaves room, and there
is work: it never finished, or there are commits since the last DONE (logs/done), e.g. a change. If it dies right
after starting 3 times in a row, it gives up until the next commit and notifies. State in logs/guard.json.
Run it from anywhere: it finds the project from its own location (or ROADMAP_ROOT).
"""
import json, os, subprocess, sys, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import serve, usage  # noqa: E402

ROOT = serve.ROOT
LIMIT = float(os.environ.get("GUARD_LIMIT", "80"))
INTERVAL = int(os.environ.get("GUARD_INTERVAL", "20"))
AUTO = os.environ.get("AUTO_RESUME", "0") == "1"
TARGET = os.environ.get("TMUX_TARGET", "loop:loop")
TMUX = ["tmux"] + (["-L", os.environ["TMUX_SOCKET"]] if os.environ.get("TMUX_SOCKET") else [])  # tmux server name
CMD = os.environ.get("RESUME_CMD", "./loopkit/run.sh")  # settings live in loopkit.env, so a plain relaunch is enough
SHELLS = {"bash", "zsh", "sh", "fish", "dash"}
STOP = os.path.join(ROOT, "STOP")
PAUSE = os.path.join(ROOT, "PAUSE")
DONE = os.path.join(ROOT, "logs", "done")
HALTED = os.path.join(ROOT, "logs", "halted")
WAITING = os.path.join(ROOT, "logs", "waiting")  # run.sh is waiting out a usage limit: leave it alone
FEAT = os.path.join(ROOT, "features.json")
STATE = os.path.join(ROOT, "logs", "guard.json")


def log(msg):
    print(time.strftime("[%F %T] ") + msg, flush=True)


def notify(msg):  # same channels as run.sh (logs/notify.log, NTFY_TOPIC, NOTIFY_CMD from loopkit.env)
    log(msg)
    script = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "notify.sh")
    try:
        subprocess.run(["bash", script, msg], cwd=ROOT, timeout=60, capture_output=True)
    except (OSError, subprocess.TimeoutExpired):
        with open(os.path.join(ROOT, "logs", "notify.log"), "a", encoding="utf-8") as fh:
            fh.write(time.strftime("[%F %T] ") + msg + "\n")


def hm(ms):
    return time.strftime("%H:%M", time.localtime(ms / 1000))


def pane_free():
    try:
        out = subprocess.run(TMUX + ["display", "-p", "-t", TARGET, "#{pane_current_command}"],
                             capture_output=True, text=True, timeout=5)
    except (OSError, subprocess.TimeoutExpired):
        return False
    return out.returncode == 0 and out.stdout.strip() in SHELLS


def read(path):
    try:
        with open(path, encoding="utf-8") as fh:
            return fh.read().strip()
    except OSError:
        return None


def head():
    try:
        r = subprocess.run(["git", "-C", ROOT, "rev-parse", "HEAD"], capture_output=True, text=True, timeout=10)
    except (OSError, subprocess.TimeoutExpired):
        return None
    return r.stdout.strip() if r.returncode == 0 else None


def relaunch():
    cmd = f"cd {ROOT} && {CMD}"
    r = subprocess.run(TMUX + ["send-keys", "-t", TARGET, cmd, "Enter"], capture_output=True, timeout=5)
    return r.returncode == 0


def main():
    try:
        with open(STATE, encoding="utf-8") as fh:
            st = json.load(fh)
    except (OSError, ValueError):
        st = {}
    st.setdefault("state", "watching")
    os.makedirs(os.path.join(ROOT, "logs"), exist_ok=True)
    log(f"Usage guard running: limit {LIMIT:.0f} % of the 5-hour window · auto resume: {'yes' if AUTO else 'no'}")
    while True:
        now = int(time.time() * 1000)
        running = serve.loop_running()
        iters, _ = serve.timeline(running)
        cost = usage.iteration_cost(usage.per_iteration(ROOT, iters))
        last = usage.latest(ROOT)
        fresh = bool(last and last["r5"] > now)  # if the window already renewed, the last sample is stale
        u5 = last["u5"] * 100 if fresh else 0.0
        s = st["state"]

        if s == "stopping":
            if not running:
                if os.path.exists(STOP):
                    os.remove(STOP)  # it was ours and has done its job; usage decides when to start again
                st.update(state="paused")
                log("The loop stopped because of usage")
            elif not os.path.exists(STOP):
                st.update(state="override")
                notify(f"You removed STOP: I will not stop the loop again until usage renews ({hm(st['reset_at'])})")
        elif s == "override" and now >= st.get("reset_at", 0):
            st.update(state="watching")
        elif s == "paused":
            if running or now >= st.get("reset_at", 0) + 60e3:  # relaunched by hand, or the window renewed
                st = {"state": "watching", "renewed": not running}

        # Auto-start: whenever there is work and nothing stands in the way
        h = head()
        if st.get("gave_up") and st["gave_up"] != h:
            st.pop("gave_up"); st["fails"] = 0
        if read(DONE) == h:
            st.update(fails=0, last_launch=0)  # it finished cleanly: the next start begins from scratch
        elif running and now - st.get("last_launch", 0) > 90e3:
            st["fails"] = 0  # the last start held up
        if (AUTO and st["state"] == "watching" and not running and h and read(DONE) != h and not st.get("gave_up")
                and os.path.exists(FEAT)  # nothing to build before the plan exists
                and not any(os.path.exists(f) for f in (STOP, PAUSE, HALTED))
                and not (fresh and u5 + cost >= LIMIT)):
            if not pane_free():
                if not st.get("warned"):
                    notify(f"There is work for the loop but {TARGET} is busy: I cannot start it")
                    st["warned"] = True
            else:
                if now - st.get("last_launch", 0) < 5 * 60e3:  # still work and not running: the previous start died
                    st["fails"] = st.get("fails", 0) + 1
                if st.get("fails", 0) >= 3:
                    st.update(gave_up=h, fails=0)
                    notify(f"The loop dies right after starting (3 times in a row): I stop starting it until the next commit. Look at tmux {TARGET}")
                elif relaunch():
                    notify("5-hour usage renewed: relaunching the loop" if st.pop("renewed", False) else "There is work: starting the loop")
                    st.update(last_launch=now, warned=False)
                    time.sleep(min(30, 3 * INTERVAL))  # let it take the lock before looking again
                    continue
        if (st["state"] == "watching" and running and fresh and u5 + cost >= LIMIT and not os.path.exists(STOP)
                and not os.path.exists(WAITING)):
            open(STOP, "w").close()
            st.update(state="stopping", reset_at=last["r5"], at=now, util=u5, warned=False)
            notify(f"5-hour usage at {u5:.0f} %: stopping the loop after the current feature. It renews at {hm(last['r5'])}"
                   + (" and I will relaunch it" if AUTO else ". Relaunch it whenever you want (./loopkit/run.sh)"))

        st.update(limit=LIMIT, margin=cost, auto_resume=AUTO, updated=now, util5=u5 if fresh else None,
                  reset5=last["r5"] if fresh else None, util7=last["u7"] * 100 if last and last.get("u7") is not None else None,
                  reset7=last["r7"] if last else None)
        tmp = STATE + ".tmp"
        with open(tmp, "w", encoding="utf-8") as fh:
            json.dump(st, fh)
        os.replace(tmp, STATE)
        time.sleep(INTERVAL)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        pass
