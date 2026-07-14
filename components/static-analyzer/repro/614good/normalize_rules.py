#!/usr/bin/env python3
"""Extract stable instrumentation-rule summaries from analyzer transcripts."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import re
import sys


ANSI_RE = re.compile(r"\x1b\[[0-?]*[ -/]*[@-~]")
PROMPT_RE = re.compile(r"What is the (branch ID|ID) to continue")
CLASS_METHOD_RE = re.compile(r"^(.+)\.java\s+([^:]+):(\d+)$")
ENTRY_RE = re.compile(r"^At function entry\s+([^\(]+)\((.*)\)$")
CALL_LINE_RE = re.compile(r"^The above function is called at the line number:\s*(.*)$")
BCI_RE = re.compile(r"^The bci for the source location is:\s*(-?\d+)$")
PARAM_RE = re.compile(r"^The parameters are:\s*(.*)$")
ID_RE = re.compile(r"^ID:\s*(\d+)$")
BRANCH_RE = re.compile(r"^Branch ID:\s*(\d+)$")
HARNESS_RE = re.compile(
    r"^\[HARNESS\]\s+round=(\d+)\s+prompt=(\w+)\s+response=(-?\d+)$"
)


def clean_lines(path: Path) -> list[str]:
    text = path.read_text(encoding="utf-8", errors="replace")
    text = ANSI_RE.sub("", text).replace("\r\n", "\n").replace("\r", "\n")
    return [line.rstrip() for line in text.splitlines()]


def split_plans(lines: list[str]) -> tuple[list[list[str]], list[dict[str, object]]]:
    plans: list[list[str]] = []
    selections: list[dict[str, object]] = []
    current: list[str] = []

    for line in lines:
        harness = HARNESS_RE.match(line.strip())
        if harness:
            selections.append(
                {
                    "round": int(harness.group(1)),
                    "prompt": harness.group(2),
                    "response": int(harness.group(3)),
                }
            )
            if harness.group(2) == "id":
                plans.append(current)
                current = []
            continue

        if PROMPT_RE.search(line):
            continue
        current.append(line)

    if current and any(ID_RE.match(line.strip()) for line in current):
        plans.append(current)
    return plans, selections


def normalize_csv(value: str) -> list[str]:
    return [part.strip() for part in value.split(",") if part.strip()]


def extract_plan(lines: list[str], round_number: int) -> dict[str, object]:
    branches: list[dict[str, object]] = []
    current_branch: dict[str, object] | None = None
    current_rule: dict[str, object] | None = None

    def ensure_branch() -> dict[str, object]:
        nonlocal current_branch
        if current_branch is None:
            current_branch = {"branch": 0, "rules": []}
            branches.append(current_branch)
        return current_branch

    for raw in lines:
        line = raw.strip()
        branch_match = BRANCH_RE.match(line)
        if branch_match:
            current_branch = {"branch": int(branch_match.group(1)), "rules": []}
            branches.append(current_branch)
            current_rule = None
            continue

        id_match = ID_RE.match(line)
        if id_match:
            current_rule = {"id": int(id_match.group(1))}
            ensure_branch()["rules"].append(current_rule)
            continue

        if current_rule is None:
            continue

        location = CLASS_METHOD_RE.match(line)
        if location:
            class_name = location.group(1).replace("/", ".")
            current_rule.update(
                {
                    "className": class_name,
                    "methodName": location.group(2),
                    "lineNumber": int(location.group(3)),
                }
            )
            continue

        entry = ENTRY_RE.match(line)
        if entry:
            current_rule["methodName"] = entry.group(1)
            current_rule["location"] = "entry"
            current_rule["parameterTypes"] = normalize_csv(entry.group(2))
            continue

        params = PARAM_RE.match(line)
        if params:
            current_rule["parameterTypes"] = normalize_csv(params.group(1))
            continue

        bci = BCI_RE.match(line)
        if bci:
            current_rule["byteCodeIndex"] = int(bci.group(1))
            continue

        called_at = CALL_LINE_RE.match(line)
        if called_at and called_at.group(1):
            current_rule["lineNumber"] = int(called_at.group(1))
            continue

        if line == "Instruction is in a loop":
            current_rule["loopId"] = 1
        elif line.startswith("Print or use an existing stacktrace"):
            current_rule["strategy"] = "STACK_TRACE"
        elif line.startswith("Accessing field member of a class"):
            current_rule["fieldAccess"] = True

    return {"round": round_number, "branches": branches}


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("transcript", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()

    plans, selections = split_plans(clean_lines(args.transcript))
    normalized = {
        "formatVersion": 1,
        "source": str(args.transcript),
        "selections": selections,
        "rounds": [extract_plan(plan, index + 1) for index, plan in enumerate(plans)],
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(normalized, indent=2, sort_keys=True) + "\n")

    if not normalized["rounds"]:
        print("No instrumentation plans found", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
