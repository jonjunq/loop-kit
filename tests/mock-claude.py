#!/usr/bin/env python3
"""Fake `claude` CLI to test run.sh without spending anything (CLAUDE_BIN=tests/mock-claude.py).

The role comes from LOOPKIT_ROLE (set by run.sh). Behaviour per feature is scripted in mock/<role>-<id> files, one
action per line, consumed in order; with no script the agent "does the work". Every session reports a cost of
MOCK_COST dollars (default 0.5) so BUDGET_USD can be tested.
"""
import json, os, subprocess, sys

prompt = sys.argv[sys.argv.index("-p") + 1]
role = os.environ.get("LOOPKIT_ROLE", "")
COST = float(os.environ.get("MOCK_COST", "0.5"))


def result(subtype="success", is_error=False, text="done"):
    print(json.dumps({"type": "system", "subtype": "init"}))
    print(json.dumps({"type": "result", "subtype": subtype, "is_error": is_error, "result": text, "total_cost_usd": COST}))


def pop(name, default):
    p = f"mock/{name}"
    if not os.path.exists(p):
        return default
    lines = open(p).read().splitlines()
    if not lines:
        return default
    open(p, "w").write("\n".join(lines[1:]))
    return lines[0]


def sh(c):
    subprocess.run(c, shell=True, check=False, capture_output=True)


def after(marker):
    return prompt.split(marker, 1)[1]


if role in ("worker", "qa"):
    fid = json.loads(after("ASSIGNED FEATURE:\n") if role == "worker" else after("FEATURE TO AUDIT:\n"))["id"]

if role == "worker":
    act = pop(f"worker-{fid}", "ok")
    if act == "limit":
        result(is_error=True, text="Claude AI usage limit reached|1730000000"); sys.exit(1)
    if act == "nodata":
        sys.exit(1)
    if act == "maxturns":
        result("error_max_turns", True, None); sys.exit(1)
    if act == "cheat":  # marks itself as done without building anything
        d = json.load(open("features.json"))
        for f in d["features"]:
            if f["id"] == fid:
                f["passes"] = True
        json.dump(d, open("features.json", "w"))
        sh(f'echo "- {fid} done (cheat)" >> PROGRESS.md && git add -A && git commit -qm "{fid}"')
        result(); sys.exit(0)
    if act == "noimpl":  # says it is done but builds nothing
        result(); sys.exit(0)
    sh(f'mkdir -p done && touch done/{fid} && echo "## 2026-01-01 · {fid} · done" >> PROGRESS.md && git add -A && git commit -qm "{fid}"')
    result(); sys.exit(0)

if role == "qa":
    act = pop(f"qa-{fid}", "PASS")
    sh("echo 'qa was here' >> src.txt && touch qa-untracked.txt")  # changes the harness must throw away
    if act != "none":
        open("logs/qa-verdict.txt", "w").write(act.replace("|", "\n") + "\n")
    result(); sys.exit(0)

if role.startswith("tester-"):
    zone = role[len("tester-"):]
    report = after("YOUR REPORT: ").strip().splitlines()[0]
    url = after("URL OF THE COPY: ").splitlines()[0].strip()
    ok = subprocess.run(["curl", "-sf", "-o", "/dev/null", url]).returncode == 0
    act = pop(f"tester-{zone}", "clean")
    sh("echo 'tester was here' >> src.txt")
    open(report, "w").write(f"# Report {zone}\ncopy reachable: {ok}\n" + ("BUG: the button does nothing\n" if act == "bug" else "no bugs\n"))
    result(); sys.exit(0)

d = json.load(open("features.json"))
if role == "triage":
    reports = after("REPORTS:\n").split()
    bugs = sum("BUG:" in open(r).read() for r in reports)
    if bugs:
        n = max(int(f["id"][1:4]) for f in d["features"] if f["id"][1:4].isdigit()) + 1
        fid = f"F{n:03d}"
        d["features"].append({"id": fid, "priority": 999, "depends_on": [], "description": "[User test 1] Fix the button",
                              "steps": [], "verify": f"test -f done/{fid}", "passes": False, "attempts": 0, "blocked": False, "notes": ""})
    json.dump(d, open("features.json", "w"), indent=1)
    sh(f"echo '- triage: {bugs} bugs' >> DECISIONS.md && echo 'triage touched code' >> src.txt")
    result(); sys.exit(0)

# replan: split the stuck ones into <id>a and redirect dependencies
act = pop("replan", "split")
if act == "split":
    stuck = [f for f in d["features"] if not f.get("passes") and not f.get("blocked") and f.get("attempts", 0) >= 3]
    for f in stuck:
        f["blocked"] = True
        f["notes"] = f"split into {f['id']}a"
        n = dict(f, id=f["id"] + "a", blocked=False, attempts=0, notes="", verify=f"test -f done/{f['id']}a")
        d["features"].append(n)
        for g in d["features"]:
            g["depends_on"] = [n["id"] if x == f["id"] else x for x in g.get("depends_on", [])]
elif act == "break":  # invalid JSON (deletes a feature) to test the validation
    d["features"] = d["features"][1:]
elif act == "noop":
    pass
json.dump(d, open("features.json", "w"), indent=1)
sh("echo 'replan touched code' >> src.txt && echo '- replan' >> DECISIONS.md")
result(); sys.exit(0)
