#!/usr/bin/env python3
"""M4/M5 leakage gate (METHODOLOGY §6 "Verification"): one streaming pass per file counting
every pattern that must not survive anonymization. Usage:

    python3 private/verify_anon.py <BUG_DIR>

Checks source/, logs/repro.log, the whole merged logs/symptom.log (production portion
included) and symptom.md for: the JIRA id and its bare number, the original failure-path
type/method names, and the original failure-path log literals.
"""
import os
import re
import sys

BUG = sys.argv[1] if len(sys.argv) > 1 else "."

PATTERNS = [
    ("HBASE-4078", False), (r"\b4078\b", True),
    (r"\bStore\b", True), (r"\bHStore\b", True),
    (r"\binternalFlushCache\b", True), (r"\bcompleteCompaction\b", True),
    (r"\bloadStoreFiles\b", True), (r"\bcompactStore\b", True),
    ("Failed open of", False), ("Renaming flushed file", False),
    ("presumption is that", False), ("corrupted at flush", False),
    ("Failed move of compacted file", False), ("Failed replacing compacted files", False),
    ("Compaction failed", False), ("Compaction Request failed", False),
    ("HBASE-646", False), ("Starting compaction of", False),
    ("Completed compaction of", False), ("Completed major compaction of", False),
    ("Replay of HLog required", False), ("Unable to rename", False),
]
COMPILED = [(p, re.compile(p.encode() if is_re else re.escape(p.encode()))) for p, is_re in PATTERNS]


def scan(path, counts):
    with open(path, "rb") as f:
        while True:
            chunk = f.read(1 << 24)
            if not chunk:
                break
            # carry a small overlap so a pattern split across chunks is still seen
            tail = f.read(256)
            if tail:
                chunk += tail
                f.seek(-256, os.SEEK_CUR)
            for p, rx in COMPILED:
                n = len(rx.findall(chunk))
                if n:
                    counts[p] = counts.get(p, 0) + n


def main():
    targets = []
    src = os.path.join(BUG, "source")
    for dirpath, _d, files in os.walk(src):
        targets += [os.path.join(dirpath, f) for f in files]
    for rel in ("logs/repro.log", "logs/symptom.log", "symptom.md"):
        p = os.path.join(BUG, rel)
        if os.path.exists(p):
            targets.append(p)

    groups = {"source/": [t for t in targets if t.startswith(src)],
              "logs/repro.log": [os.path.join(BUG, "logs/repro.log")],
              "logs/symptom.log": [os.path.join(BUG, "logs/symptom.log")],
              "symptom.md": [os.path.join(BUG, "symptom.md")]}
    bad = 0
    for name, files in groups.items():
        counts = {}
        for f in files:
            if os.path.exists(f):
                scan(f, counts)
        if counts:
            bad = 1
            print("%-18s LEAKS: %s" % (name, ", ".join("%s=%d" % kv for kv in sorted(counts.items()))))
        else:
            print("%-18s clean (%d file(s))" % (name, len([f for f in files if os.path.exists(f)])))
    print("RESULT:", "LEAKAGE" if bad else "no leakage")
    return bad


if __name__ == "__main__":
    sys.exit(main())
