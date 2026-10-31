"""Subscription usage (5-hour and 7-day windows) read from the rate_limit_event lines Claude Code writes to logs/iter-*.jsonl.

Used by serve.py (to show it) and guard.py (to stop the loop before the limit). Only subscription plans emit these
events; with an API key there is no window and both simply show nothing. Standard library only.
"""
import glob, json, os, threading

_lock = threading.Lock()  # serve.py answers requests in parallel
_cache = {}  # path -> {"off": bytes read, "first": sample, "last": sample}


def _sample(line):
    try:
        info = json.loads(line)["rate_limit_info"]
        w = info.get("unifiedWindows") or {}
        f, s = w.get("five_hour") or {}, w.get("seven_day") or {}
        if "utilization" not in f:
            return None
        return {"u5": f["utilization"], "r5": int(f.get("resetsAt") or info.get("resetsAt") or 0) * 1000,
                "u7": s.get("utilization"), "r7": int(s.get("resetsAt") or 0) * 1000}
    except (ValueError, KeyError, TypeError):
        return None


def file_usage(path):
    """First and last usage sample of a jsonl. Incremental: only reads what is new since last time."""
    try:
        size = os.path.getsize(path)
    except OSError:
        return None
    with _lock:
        return _read(path, size)


def _read(path, size):
    c = _cache.get(path)
    if not c or size < c["off"]:
        c = _cache[path] = {"off": 0, "first": None, "last": None}
    if size > c["off"]:
        with open(path, "rb") as fh:
            fh.seek(c["off"])
            chunk = fh.read()
        end = chunk.rfind(b"\n") + 1  # whole lines only
        for line in chunk[:end].split(b"\n"):
            if b'"rate_limit_event"' in line:
                s = _sample(line)
                if s:
                    c["first"] = c["first"] or s
                    c["last"] = s
        c["off"] += end
    return c


def per_iteration(root, iters, n=30):
    """Usage at the start and end of each of the last n iterations (worker + QA)."""
    out = []
    for it in iters[-n:]:
        w = file_usage(os.path.join(root, "logs", f"iter-{it['iter']:05d}-worker.jsonl"))
        q = file_usage(os.path.join(root, "logs", f"iter-{it['iter']:05d}-qa.jsonl"))
        first = (w and w["first"]) or (q and q["first"])
        last = (q and q["last"]) or (w and w["last"])
        if first and last:
            out.append({"iter": it["iter"], "start": it["start"], "end": it.get("end"),
                        "u0": first["u5"], "u1": last["u5"], "r0": first["r5"], "r1": last["r5"], "u7": last["u7"]})
    return out


def latest(root, k=6):
    """Latest known sample (from the most recent jsonl files) or None."""
    files = sorted(glob.glob(os.path.join(root, "logs", "iter-*.jsonl")), key=os.path.getmtime, reverse=True)
    for p in files[:k]:
        c = file_usage(p)
        if c and c["last"]:
            return dict(c["last"], mtime=int(os.path.getmtime(p) * 1000))
    return None


def iteration_cost(samples, default=5.0):
    """5-hour usage points (0-100) a typical iteration spends: 75th percentile of the last 10, between 3 and 15."""
    d = sorted((s["u1"] - s["u0"]) * 100 for s in samples[-10:] if s["r0"] == s["r1"] and s["u1"] >= s["u0"])
    if len(d) < 3:
        return default
    return max(3.0, min(15.0, d[min(len(d) - 1, int(len(d) * 0.75))]))


def read_guard(root):
    try:
        with open(os.path.join(root, "logs", "guard.json"), encoding="utf-8") as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return None
