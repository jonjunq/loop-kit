#!/usr/bin/env python3
"""loop-kit roadmap viewer. Standard library only. Serves roadmap/index.html and /api/state (read-only)."""
import fcntl, json, os, re, subprocess, time
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
from urllib.parse import parse_qs, urlparse

import usage

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.environ.get("ROADMAP_ROOT") or os.path.dirname(os.path.dirname(HERE))  # <project>/loopkit/roadmap
PORT = int(os.environ.get("ROADMAP_PORT", "8090"))
HOST = os.environ.get("ROADMAP_HOST", "0.0.0.0")
NAME = os.environ.get("PROJECT_NAME") or os.path.basename(os.path.abspath(ROOT)).capitalize()
USER = os.environ.get("ROADMAP_USER", "")  # name in the greeting; empty = no name

LINE = re.compile(r"^\[(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d)\] (.*)$")


def tail(path, n):
    try:
        with open(os.path.join(ROOT, path), encoding="utf-8", errors="replace") as fh:
            return fh.read().splitlines()[-n:]
    except OSError:
        return []


def loop_running():
    lock = os.path.join(ROOT, "logs", ".lock")
    if not os.path.exists(lock):
        return False
    try:
        with open(lock) as fh:
            fcntl.flock(fh, fcntl.LOCK_EX | fcntl.LOCK_NB)
            fcntl.flock(fh, fcntl.LOCK_UN)
        return False  # nadie tiene el lock
    except OSError:
        return True


def mtime_ms(path):
    try:
        return int(os.path.getmtime(os.path.join(ROOT, path)) * 1000)
    except OSError:
        return None


def timeline(running):
    """Rebuilds the loop iterations from logs/loop.log (lines '[date] text'). Understands English and Spanish logs."""
    iters, events, cur = [], [], None

    def close(end, outcome, reason=""):
        nonlocal cur
        if cur:
            cur.update(end=end, outcome=outcome, reason=reason[:300])
            # Phases: end of the worker and of the verify from their files' mtime, if inside the iteration
            w = mtime_ms(f"logs/iter-{cur['iter']:05d}-worker.jsonl")
            v = mtime_ms(f"logs/verify-{cur['id']}.log")
            if w and cur["start"] <= w <= end:
                cur["worker_end"] = w
                if v and w <= v <= end:
                    cur["verify_end"] = v
            iters.append(cur)
            cur = None

    for raw in tail("logs/loop.log", 200000):
        m = LINE.match(raw)
        if not m:
            continue
        ts = int(time.mktime(time.strptime(m.group(1), "%Y-%m-%d %H:%M:%S")) * 1000)
        text = m.group(2)
        it = re.match(r"Iter (\d+) \| (F[\w.-]+) \|", text)
        if it:
            close(ts, "interrupted")
            cur = {"iter": int(it.group(1)), "id": it.group(2), "start": ts}
            continue
        if cur:
            fid = re.escape(cur["id"])
            if re.match(fid + r" (PASS|PASA)\b", text):
                close(ts, "pass"); continue
            if re.match(fid + r" (FAIL|FALLA)", text):
                close(ts, "fail", text.split(":", 1)[-1].strip()); continue
            if re.match(fid + r": QA (inconclusive|no concluyó)", text):
                close(ts, "qa_inconclusive", text); continue
        for pat, kind in ((r"^(Start|Arranque)\b", "start"), (r"^STOP (found|encontrado)", "stop"), (r"^Replan ", "replan"),
                          (r"^(Regression sweep|Barrido de regresiones)", "sweep"), (r"^(Regressions|Regresiones):", "regression"),
                          (r"^(DONE|TERMINADO)", "done"), (r"^(HALTED|PARADO|BUDGET)", "halt"),
                          (r"(blocked by the harness|bloqueada por el arnés)", "blocked")):
            if re.search(pat, text):
                if kind in ("start", "stop", "halt", "done", "replan", "sweep"):
                    close(ts, "interrupted")
                events.append({"ts": ts, "kind": kind, "text": text[:300]})
                break
    if cur:
        if running:
            w = mtime_ms(f"logs/iter-{cur['iter']:05d}-worker.jsonl")
            q = mtime_ms(f"logs/iter-{cur['iter']:05d}-qa.jsonl")
            cur["phase"] = "qa" if q and q >= cur["start"] and w and q >= w else "worker"
            cur.update(end=None, outcome="running")
            iters.append(cur)
        else:
            close(mtime_ms("logs/loop.log") or cur["start"], "interrupted")
    return iters, events


def state():
    try:
        with open(os.path.join(ROOT, "features.json"), encoding="utf-8") as fh:
            feats = json.load(fh).get("features", [])
    except (OSError, ValueError) as e:
        feats, err = [], str(e)
    else:
        err = None
    running = loop_running()
    iters, events = timeline(running)
    current = next((i["id"] for i in reversed(iters)), None)
    last = usage.latest(ROOT)
    try:
        git = subprocess.run(["git", "log", "--date=format:%d/%m %H:%M", "--pretty=%ad  %s", "-n", "20"],
                             cwd=ROOT, capture_output=True, text=True, timeout=5).stdout.splitlines()
    except Exception:
        git = []
    return {
        "now": int(time.time() * 1000), "project": NAME, "user": USER, "features": feats, "error": err, "running": running, "current": current,
        "iterations": iters, "events": events,
        "loop": tail("logs/loop.log", 40), "decisions": tail("DECISIONS.md", 60),
        "git": git,
        "usage": {"latest": last, "per_iter": usage.per_iteration(ROOT, iters), "guard": usage.read_guard(ROOT)},
    }


def feature_notes(fid):
    """PROGRESS.md sections about a feature (header '## date · Fxxx · title')."""
    out, cur = [], None
    for line in tail("PROGRESS.md", 100000):
        if line.startswith("## "):
            cur = [line] if re.search(r"\b" + re.escape(fid) + r"\b", line) else None
            if cur:
                out.append(cur)
        elif cur is not None:
            cur.append(line)
    return ["\n".join(c).strip() for c in out[-4:]]


class H(BaseHTTPRequestHandler):
    def _send(self, code, body, ctype):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path.startswith("/api/state"):
            self._send(200, json.dumps(state(), ensure_ascii=False).encode(), "application/json; charset=utf-8")
        elif self.path.startswith("/api/feature"):
            fid = parse_qs(urlparse(self.path).query).get("id", [""])[0]
            body = {"id": fid, "progress": feature_notes(fid) if re.fullmatch(r"F[\w.-]+", fid) else []}
            self._send(200, json.dumps(body, ensure_ascii=False).encode(), "application/json; charset=utf-8")
        elif urlparse(self.path).path in ("/", "/index.html"):
            with open(os.path.join(HERE, "index.html"), "rb") as fh:
                self._send(200, fh.read(), "text/html; charset=utf-8")
        else:
            self._send(404, b"not found", "text/plain")

    def log_message(self, *a):
        pass


if __name__ == "__main__":
    print(f"{NAME} roadmap on http://localhost:{PORT}  (Ctrl+C to quit)", flush=True)
    try:
        ThreadingHTTPServer((HOST, PORT), H).serve_forever()
    except KeyboardInterrupt:
        pass
