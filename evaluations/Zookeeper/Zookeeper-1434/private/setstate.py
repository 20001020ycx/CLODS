#!/usr/bin/env python3
"""Atomically update one milestone in state.json.
usage: setstate.py M2 IN_PROGRESS [--note "..."] [--artifacts a b c]"""
import json, os, sys, tempfile, subprocess, argparse
P = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "state.json")
ap = argparse.ArgumentParser()
ap.add_argument("mid"); ap.add_argument("status")
ap.add_argument("--note", default=None); ap.add_argument("--artifacts", nargs="*", default=None)
a = ap.parse_args()
now = subprocess.check_output(["date","-u","+%FT%TZ"]).decode().strip()
OUT = {"DONE":("success",True),"FAILED":("failed",False),"BLOCKED":("blocked",None),
       "IN_PROGRESS":("in_progress",None),"PENDING":("pending",None)}
d = json.load(open(P))
for m in d["milestones"]:
    if m["id"] != a.mid: continue
    m["status"] = a.status
    m["outcome"], m["success"] = OUT[a.status]
    if a.status == "IN_PROGRESS":
        m["started"] = now; m["attempts"] = m.get("attempts",0) + 1; m["by"] = "agent-run-57ce8ccf"
    if a.status in ("DONE","FAILED"): m["finished"] = now; m["by"] = "agent-run-57ce8ccf"
    if a.note is not None: m["note"] = a.note
    if a.artifacts is not None: m["artifacts"] = a.artifacts
    break
else:
    sys.exit(f"no milestone {a.mid}")
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(os.path.abspath(P)), suffix=".tmp")
with os.fdopen(fd,"w") as f: json.dump(d,f,indent=2); f.write("\n")
os.replace(tmp, os.path.abspath(P))
print(f"{a.mid} -> {a.status} @ {now}")
