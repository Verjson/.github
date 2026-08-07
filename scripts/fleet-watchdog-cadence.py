#!/usr/bin/env python3
"""Record the observed interval between scheduled fleet-watchdog runs."""

from __future__ import annotations

from datetime import datetime
import json
import os
from pathlib import Path
import subprocess
import sys


class CadenceError(Exception):
    pass


def required_env(name: str) -> str:
    value = os.environ.get(name, "").strip()
    if not value:
        raise CadenceError(f"{name} is required")
    return value


def parse_timestamp(value: object, run_id: object) -> datetime:
    if not isinstance(value, str):
        raise CadenceError(f"run {run_id} has no valid created_at")
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError as error:
        raise CadenceError(f"run {run_id} has invalid created_at: {value}") from error
    if parsed.tzinfo is None:
        raise CadenceError(f"run {run_id} has invalid created_at: {value}")
    return parsed


def scheduled_runs(repository: str) -> list[dict]:
    result = subprocess.run(
        [
            "gh",
            "api",
            "--method",
            "GET",
            f"repos/{repository}/actions/workflows/fleet-watchdog.yml/runs",
            "-f",
            "event=schedule",
            "-f",
            "per_page=100",
        ],
        check=True,
        text=True,
        capture_output=True,
    )
    try:
        payload = json.loads(result.stdout)
    except json.JSONDecodeError as error:
        raise CadenceError("workflow run history was not valid JSON") from error
    runs = payload.get("workflow_runs") if isinstance(payload, dict) else None
    if not isinstance(runs, list) or not all(isinstance(run, dict) for run in runs):
        raise CadenceError("workflow run history has no workflow_runs list")
    return [run for run in runs if run.get("event") == "schedule"]


def main() -> int:
    repository = required_env("GITHUB_REPOSITORY")
    summary_path = Path(required_env("GITHUB_STEP_SUMMARY"))
    try:
        run_id = int(required_env("GITHUB_RUN_ID"))
        threshold_minutes = int(required_env("WATCHDOG_MAX_GAP_MINUTES"))
    except ValueError as error:
        raise CadenceError("GITHUB_RUN_ID and WATCHDOG_MAX_GAP_MINUTES must be integers") from error
    if threshold_minutes <= 0:
        raise CadenceError("WATCHDOG_MAX_GAP_MINUTES must be positive")

    runs = scheduled_runs(repository)
    current = next((run for run in runs if run.get("id") == run_id), None)
    if current is None:
        raise CadenceError(f"current scheduled run {run_id} was not found")
    current_at = parse_timestamp(current.get("created_at"), run_id)

    prior: list[tuple[datetime, dict]] = []
    for run in runs:
        if run.get("id") == run_id:
            continue
        created_at = parse_timestamp(run.get("created_at"), run.get("id"))
        if created_at < current_at:
            prior.append((created_at, run))

    lines = ["## Fleet watchdog cadence", "", f"Current scheduled run: `{run_id}` at `{current_at.isoformat()}`."]
    if not prior:
        lines.extend(["", "No earlier scheduled run is available for comparison."])
        summary_path.write_text("\n".join(lines) + "\n", encoding="utf-8")
        return 0

    previous_at, previous = max(prior, key=lambda item: item[0])
    gap_seconds = int((current_at - previous_at).total_seconds())
    gap_minutes = gap_seconds // 60
    exceeded = gap_seconds > threshold_minutes * 60
    status = (
        f"scheduler gap exceeded the {threshold_minutes}-minute observation threshold"
        if exceeded
        else f"within the {threshold_minutes}-minute observation threshold"
    )
    lines.extend(
        [
            f"Previous scheduled run: `{previous.get('id')}` at `{previous_at.isoformat()}`.",
            "",
            f"Gap: {gap_minutes} minutes.",
            f"Status: {status}.",
        ]
    )
    summary_path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    if exceeded:
        print(
            "::warning title=Fleet watchdog cadence gap::"
            f"Observed {gap_minutes} minutes between scheduled runs "
            f"{previous.get('id')} and {run_id}; the watchdog remains a best-effort backstop."
        )
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (CadenceError, subprocess.CalledProcessError) as error:
        print(f"fleet-watchdog-cadence: {error}", file=sys.stderr)
        raise SystemExit(1)
