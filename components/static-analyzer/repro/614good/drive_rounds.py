#!/usr/bin/env python3
"""Drive the five recorded manual-selection rounds of StaticAnalysisLLVM.

Uses only the Python standard library so it also works in the historical
container image.
"""

from __future__ import annotations

import argparse
import codecs
import json
import os
from pathlib import Path
import pty
import select
import signal
import subprocess
import sys
import time


ID_PROMPT = "What is the ID to continue"
BRANCH_PROMPT = "What is the branch ID to continue"
DIVERGENCE_PROMPT = "Was there a divergence point?"


def load_schedule(path: Path) -> list[tuple[str, str, int]]:
    manifest = json.loads(path.read_text())
    return [
        (item["prompt"], str(item["response"]), item["round"])
        for item in manifest["recordedSelections"]
    ]


def write_result(path: Path, **fields: object) -> None:
    path.write_text(json.dumps(fields, indent=2, sort_keys=True) + "\n")


def terminate(process: subprocess.Popen[bytes]) -> None:
    if process.poll() is not None:
        return
    for sig, delay in ((signal.SIGINT, 0.5), (signal.SIGTERM, 0.5), (signal.SIGKILL, 0.0)):
        try:
            process.send_signal(sig)
        except ProcessLookupError:
            return
        if delay:
            try:
                process.wait(timeout=delay)
                return
            except subprocess.TimeoutExpired:
                pass


def wait_for_prompt(
    master_fd: int,
    process: subprocess.Popen[bytes],
    log,
    candidates: list[str],
    timeout: int,
    max_transcript_bytes: int,
) -> tuple[str, str]:
    deadline = time.monotonic() + timeout
    decoder = codecs.getincrementaldecoder("utf-8")(errors="replace")
    searchable = ""

    while True:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            return "timeout", searchable
        ready, _, _ = select.select([master_fd], [], [], min(remaining, 1.0))
        if not ready:
            if process.poll() is not None:
                return "eof", searchable
            continue
        try:
            chunk = os.read(master_fd, 65536)
        except OSError:
            chunk = b""
        if not chunk:
            return "eof", searchable
        text = decoder.decode(chunk)
        if log.tell() + len(text.encode("utf-8")) > max_transcript_bytes:
            return "transcript-limit", searchable
        log.write(text)
        log.flush()
        searchable += text
        for candidate in candidates:
            if candidate in searchable:
                return candidate, searchable
        # Prompts are short; bound memory without losing a split prompt.
        searchable = searchable[-8192:]


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--binary", required=True)
    parser.add_argument("--cwd", required=True)
    parser.add_argument("--transcript", required=True)
    parser.add_argument("--result", required=True)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--prompt-timeout", type=int, default=900)
    parser.add_argument("--max-transcript-bytes", type=int, default=64 * 1024 * 1024)
    args = parser.parse_args()

    transcript_path = Path(args.transcript)
    result_path = Path(args.result)
    transcript_path.parent.mkdir(parents=True, exist_ok=True)
    schedule = load_schedule(args.manifest)

    completed: list[dict[str, object]] = []
    started = time.monotonic()
    outcome = "driver-error"
    detail = "unknown driver failure"

    with transcript_path.open("w", encoding="utf-8", errors="replace") as log:
        master_fd, slave_fd = pty.openpty()
        try:
            process = subprocess.Popen(
                [args.binary],
                cwd=args.cwd,
                stdin=slave_fd,
                stdout=slave_fd,
                stderr=slave_fd,
                close_fds=True,
                start_new_session=True,
                env=os.environ.copy(),
            )
        except Exception:
            os.close(master_fd)
            os.close(slave_fd)
            raise
        os.close(slave_fd)

        try:
            for expected_kind, response, round_number in schedule:
                expected = BRANCH_PROMPT if expected_kind == "branch" else ID_PROMPT
                found, _ = wait_for_prompt(
                    master_fd,
                    process,
                    log,
                    [expected, DIVERGENCE_PROMPT],
                    args.prompt_timeout,
                    args.max_transcript_bytes,
                )
                if found == expected:
                    marker = (
                        f"\n[HARNESS] round={round_number} prompt={expected_kind} "
                        f"response={response}\n"
                    )
                    log.write(marker)
                    log.flush()
                    os.write(master_fd, (response + "\n").encode())
                    completed.append(
                        {
                            "round": round_number,
                            "prompt": expected_kind,
                            "response": int(response),
                        }
                    )
                    continue
                if found == DIVERGENCE_PROMPT:
                    outcome = "incomplete-unrecorded-divergence-input"
                    detail = (
                        f"The analyzer requested divergence input before the recorded "
                        f"{expected_kind} selection for round {round_number}."
                    )
                elif found == "eof":
                    outcome = "exited-before-required-round"
                    detail = (
                        f"The analyzer exited before the recorded {expected_kind} "
                        f"selection for round {round_number}."
                    )
                elif found == "transcript-limit":
                    outcome = "transcript-size-limit"
                    detail = (
                        f"Analyzer output exceeded {args.max_transcript_bytes} bytes "
                        f"while waiting for round {round_number}."
                    )
                else:
                    outcome = "watchdog-timeout"
                    detail = (
                        f"No recognized prompt appeared within {args.prompt_timeout} seconds "
                        f"while waiting for round {round_number}."
                    )
                break
            else:
                found, _ = wait_for_prompt(
                    master_fd,
                    process,
                    log,
                    [BRANCH_PROMPT, ID_PROMPT, DIVERGENCE_PROMPT],
                    args.prompt_timeout,
                    args.max_transcript_bytes,
                )
                if found in (BRANCH_PROMPT, ID_PROMPT):
                    next_prompt = "branch" if found == BRANCH_PROMPT else "id"
                    outcome = "stopped-before-unspecified-round-6-selection"
                    detail = f"Captured the next plan and stopped at its {next_prompt} prompt."
                elif found == DIVERGENCE_PROMPT:
                    outcome = "incomplete-unrecorded-divergence-input"
                    detail = "The next required input was an undocumented divergence answer."
                elif found == "eof":
                    return_code = process.poll()
                    if return_code in (None, 0):
                        outcome = "exited-after-round-5"
                        detail = "The analyzer exited after the fifth supplied selection."
                    else:
                        outcome = "analyzer-error-after-round-5"
                        detail = (
                            "The analyzer exited with status "
                            f"{return_code} after the fifth supplied selection."
                        )
                elif found == "transcript-limit":
                    outcome = "transcript-size-limit"
                    detail = (
                        f"Analyzer output exceeded {args.max_transcript_bytes} bytes "
                        "after Round 5."
                    )
                else:
                    outcome = "watchdog-timeout"
                    detail = (
                        f"No next prompt appeared within {args.prompt_timeout} seconds "
                        "after Round 5."
                    )
        except Exception as exc:
            outcome = "driver-error"
            detail = f"{type(exc).__name__}: {exc}"
        finally:
            terminate(process)
            os.close(master_fd)

    return_code = process.poll()
    write_result(
        result_path,
        outcome=outcome,
        detail=detail,
        completedSelections=completed,
        completedSelectionCount=len(completed),
        expectedSelectionCount=len(schedule),
        elapsedSeconds=round(time.monotonic() - started, 3),
        childReturnCode=return_code,
    )
    return 0 if outcome in {
        "stopped-before-unspecified-round-6-selection",
        "incomplete-unrecorded-divergence-input",
        "exited-after-round-5",
    } and len(completed) == len(schedule) else 2


if __name__ == "__main__":
    sys.exit(main())
