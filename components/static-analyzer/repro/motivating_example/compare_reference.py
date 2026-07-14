#!/usr/bin/env python3
"""Compare normalized analyzer rounds with the author-supplied reference."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import sys


def compare(actual: dict, manifest: dict) -> dict:
    mismatches: list[str] = []
    reference = {
        item["round"]: {
            branch["branch"]: branch["rules"] for branch in item["branches"]
        }
        for item in manifest["expectedRounds"]
    }
    actual_rounds = {item["round"]: item for item in actual.get("rounds", [])}
    unexpected_rounds = sorted(set(actual_rounds) - set(reference))
    if unexpected_rounds:
        mismatches.append(f"unexpected rounds: {unexpected_rounds}")
    for round_number, expected_branches in reference.items():
        round_data = actual_rounds.get(round_number)
        if not round_data:
            mismatches.append(f"missing round {round_number}")
            continue
        branches = {item["branch"]: item["rules"] for item in round_data["branches"]}
        unexpected_branches = sorted(set(branches) - set(expected_branches))
        if unexpected_branches:
            mismatches.append(
                f"round {round_number}: unexpected branches {unexpected_branches}"
            )
        for branch_number, expected_rules in expected_branches.items():
            rules = branches.get(branch_number)
            if rules is None:
                mismatches.append(f"round {round_number}: missing branch {branch_number}")
                continue
            if len(rules) != len(expected_rules):
                mismatches.append(
                    f"round {round_number} branch {branch_number}: "
                    f"expected {len(expected_rules)} rules, got {len(rules)}"
                )
            for index, expected in enumerate(expected_rules):
                if index >= len(rules):
                    break
                rule = rules[index]
                for field, expected_value in expected.items():
                    if rule.get(field) != expected_value:
                        mismatches.append(
                            f"round {round_number} branch {branch_number} rule {index}: "
                            f"{field} expected {expected_value!r}, got {rule.get(field)!r}"
                        )

    matched_rounds = []
    for round_number in sorted(reference):
        prefix = f"round {round_number}"
        if not any(
            message.startswith(prefix) or message == f"missing round {round_number}"
            for message in mismatches
        ):
            matched_rounds.append(round_number)
    if 6 in reference:
        note = "All reference rounds (including round 6) were supplied and compared."
    else:
        note = "Round 6 is intentionally excluded because no historical reference was supplied."
    return {
        "match": not mismatches,
        "matchedRounds": matched_rounds,
        "mismatches": mismatches,
        "note": note,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("normalized", type=Path)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    actual = json.loads(args.normalized.read_text())
    manifest = json.loads(args.manifest.read_text())
    result = compare(actual, manifest)
    args.output.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
    print("MATCH" if result["match"] else "MISMATCH")
    for mismatch in result["mismatches"]:
        print(mismatch)
    return 0 if result["match"] else 1


if __name__ == "__main__":
    sys.exit(main())
