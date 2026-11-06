#!/usr/bin/env python3
"""Fake `claude` CLI to test run.sh without spending anything (CLAUDE_BIN=tests/mock-claude.py).

The role comes from LOOPKIT_ROLE (set by run.sh). Behaviour per feature is scripted in mock/<role>-<id> files, one
action per line, consumed in order; with no script the agent "does the work". Every session reports a cost of
MOCK_COST dollars (default 0.5) so BUDGET_USD can be tested. Sessions get an id and can be resumed (--resume <id>):
the mock keeps each session's prompt in mock/sessions/ and logs every resume to mock/resumed. The last prompt of each
role is saved to mock/prompt-<role> for the tests to read.
"""
import json, os, subprocess, sys, time, uuid

args = sys.argv[1:]
prompt = args[args.index("-p") + 1]
role = os.environ.get("LOOPKIT_ROLE", "")
COST = float(os.environ.get("MOCK_COST", "0.5"))
os.makedirs("mock/sessions", exist_ok=True)
if "--resume" in args:
    SID = args[args.index("--resume") + 1]
    open("mock/resumed", "a").write(SID + "\n")
    if os.path.exists("mock/resume-fail") or not os.path.exists(f"mock/sessions/{SID}"):  # as Claude Code says it
        msg = f"No conversation found with session ID: {SID}"
        print(json.dumps({"type": "result", "subtype": "error_during_execution", "is_error": True, "num_turns": 0,
                          "session_id": SID, "total_cost_usd": 0, "errors": [msg]}))
        sys.stderr.write(msg + "\n"); sys.exit(1)
    prompt = open(f"mock/sessions/{SID}").read()
else:
    SID = str(uuid.uuid4())
    open(f"mock/sessions/{SID}", "w").write(prompt)
open(f"mock/prompt-{role}", "w").write(prompt)


def emit(**m):
    print(json.dumps(dict(m, session_id=SID)), flush=True)


def result(subtype="success", is_error=False, text="done"):
    emit(type="system", subtype="init")
    emit(type="result", subtype=subtype, is_error=is_error, result=text, total_cost_usd=COST)


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


def work(fid):
    sh(f'mkdir -p done && touch done/{fid} && echo "## 2026-01-01 · {fid} · done" >> PROGRESS.md && git add -A && git commit -qm "{fid}"')


if role in ("worker", "qa"):
    fid = json.JSONDecoder().raw_decode(after("ASSIGNED FEATURE:\n" if role == "worker" else "FEATURE TO AUDIT:\n"))[0]["id"]

if role == "worker":
    act = pop(f"worker-{fid}", "ok")
    if act == "limit":
        result(is_error=True, text="Claude AI usage limit reached|1730000000"); sys.exit(1)
    if act == "nodata":
        sys.exit(1)
    if act == "maxturns":
        result("error_max_turns", True, None); sys.exit(1)
    if act == "limit-at":  # works a bit, then hits the usage limit, which resets in MOCK_RESET_IN seconds
        emit(type="system", subtype="init")
        emit(type="assistant", message={"content": [{"type": "text", "text": "starting"}]})
        info = {"status": "rejected", "resetsAt": int(time.time()) + int(os.environ.get("MOCK_RESET_IN", "7200")), "rateLimitType": "five_hour"}
        emit(type="rate_limit_event", rate_limit_info=info, uuid=str(uuid.uuid4()))
        emit(type="assistant", message={"content": [{"type": "text", "text": "You've hit your limit"}]}, error="rate_limit",
             api_error="usage_limit_reached", api_error_params={"rate_limit_info": info})
        emit(type="result", subtype="success", is_error=True, result="You've hit your limit · resets 3pm", total_cost_usd=COST)
        sys.exit(1)
    if act == "hang":  # starts a detached "server" and then goes silent
        child = subprocess.Popen(["setsid", "sleep", "300"])
        open("mock/hang.pid", "w").write(str(child.pid))
        emit(type="system", subtype="init")
        time.sleep(300); sys.exit(0)
    if act == "server":  # leaves a detached "dev server" running and does the work
        child = subprocess.Popen(["setsid", "sleep", "300"])
        open("mock/server.pid", "w").write(str(child.pid))
        work(fid); result(); sys.exit(0)
    if act == "harness":  # edits the harness and its settings, then does the work
        sh("echo 'worker was here' >> loopkit/prompts/QA.md && touch loopkit/evil.sh && echo MODEL=haiku >> loopkit.env"
           " && { ! test -f demo.env || echo 'DEMO_PORT=1' >> demo.env; }")
        work(fid); result(); sys.exit(0)
    if act == "weaken":  # deletes an old test and skips a new one, then does the work
        sh("git rm -q tests/old_test.py && mkdir -p tests && echo \"it.skip('works', () => {})\" > tests/new_test.js")
        work(fid); result(); sys.exit(0)
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
    work(fid)
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

if role.startswith("security-") and role != "security-triage":
    area = role[len("security-"):]
    report = after("YOUR REPORT: ").strip().splitlines()[0]
    act = pop(f"security-{area}", "clean")
    sh("echo 'reviewer was here' >> src.txt && touch reviewer-untracked.txt")
    open(report, "w").write(f"# Security {area}\n" + ("FINDING: anyone can read the dev mailbox\n" if act == "finding" else "nothing exploitable\n"))
    result(); sys.exit(0)

d = json.load(open("features.json"))
if role == "security-triage":
    reports = after("REPORTS:\n").split()
    found = sum("FINDING:" in open(r).read() for r in reports)
    if found:
        n = max(int(f["id"][1:4]) for f in d["features"] if f["id"][1:4].isdigit()) + 1
        fid = f"F{n:03d}"
        d["features"].append({"id": fid, "priority": 999, "depends_on": [], "description": "[Security 1] Close the dev mailbox",
                              "steps": [], "verify": f"test -f done/{fid}", "passes": False, "attempts": 0, "blocked": False, "notes": ""})
    json.dump(d, open("features.json", "w"), indent=1)
    sh(f"echo '- security triage: {found} findings' >> DECISIONS.md && echo 'security triage touched code' >> src.txt")
    result(); sys.exit(0)
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
