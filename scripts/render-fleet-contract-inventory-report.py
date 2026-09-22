#!/usr/bin/env python3
"""Render the read-only contract inventory as a compact workflow report."""

from __future__ import annotations

import argparse
import csv
import html
import io
import sys
from pathlib import Path

CONTRACT_FIELDS = ("repo", "adopter_file", "upstream_path", "pinned_sha", "status")
HEADER_FIELDS = ("repo", "adopter_file", "header_sha", "file_uses_sha", "header_invariant")
MAX_DIAGNOSTIC_LINES = 50
MAX_DIAGNOSTIC_CELL_CHARS = 500
DIAGNOSTIC_PREFIXES = (
    "rows=",
    "unreachable:",
    "unreadable:",
    "incomplete listing:",
    "truncated tree:",
)


def parse_table(rows: list[list[str]], fields: tuple[str, ...]) -> list[dict[str, str]]:
    if not rows or tuple(rows[0]) != fields:
        raise ValueError(f"expected TSV columns {fields!r}")
    if any(len(row) != len(fields) for row in rows[1:]):
        raise ValueError("inventory contains a row with the wrong number of columns")
    return [dict(zip(fields, row)) for row in rows[1:]]


def parse_inventory(text: str) -> tuple[list[dict[str, str]], list[dict[str, str]]]:
    tables: list[list[list[str]]] = []
    table: list[list[str]] = []
    for row in csv.reader(io.StringIO(text), delimiter="\t"):
        if row:
            table.append(row)
        elif table:
            tables.append(table)
            table = []
    if table:
        tables.append(table)
    if len(tables) != 2:
        raise ValueError("inventory must contain contract and header tables")
    return parse_table(tables[0], CONTRACT_FIELDS), parse_table(tables[1], HEADER_FIELDS)


def markdown_cell(value: str) -> str:
    escaped = html.escape(value.replace("\r", " ").replace("\n", " "), quote=False)
    replacements = {
        "\\": "&#92;",
        "`": "&#96;",
        "*": "&#42;",
        "[": "&#91;",
        "]": "&#93;",
        "(": "&#40;",
        ")": "&#41;",
        "!": "&#33;",
        "|": "&#124;",
    }
    return "".join(replacements.get(character, character) for character in escaped)


def render_table(rows: list[dict[str, str]], fields: tuple[str, ...], labels: tuple[str, ...]) -> list[str]:
    lines = ["| " + " | ".join(labels) + " |", "| " + " | ".join("---" for _ in labels) + " |"]
    for row in rows:
        lines.append("| " + " | ".join(markdown_cell(row[field]) for field in fields) + " |")
    return lines


def diagnostic_cell(value: str) -> str:
    escaped = markdown_cell(value)
    if len(escaped) > MAX_DIAGNOSTIC_CELL_CHARS:
        return escaped[:MAX_DIAGNOSTIC_CELL_CHARS] + "… [truncated]"
    return escaped


def render_report(inventory: str, diagnostics: str, generated_at: str, inventory_status: int) -> str:
    parse_error = None
    try:
        references, headers = parse_inventory(inventory)
    except ValueError as error:
        if inventory_status == 0:
            raise
        references, headers = [], []
        parse_error = str(error)

    drifted = [row for row in references if row["status"] == "DRIFTED"]
    unknown = [row for row in references if row["status"] == "UNKNOWN"]
    header_anomalies = [row for row in headers if row["header_invariant"] != "CONSISTENT"]
    statuses = sorted({row["status"] for row in references})
    raw_diagnostics = diagnostics.splitlines()
    if inventory_status != 0:
        failure_diagnostics = [
            line for line in raw_diagnostics
            if line.startswith(DIAGNOSTIC_PREFIXES) or line.startswith(("fatal:", "gh:"))
        ]
        diagnostics_lines = [
            diagnostic_cell(line) for line in failure_diagnostics[:MAX_DIAGNOSTIC_LINES]
        ]
        if len(failure_diagnostics) > MAX_DIAGNOSTIC_LINES:
            diagnostics_lines.append(diagnostic_cell("Additional diagnostic lines omitted."))
        if parse_error is not None:
            diagnostics_lines.append(diagnostic_cell(f"Inventory output unavailable: {parse_error}"))
        elif not diagnostics_lines:
            diagnostics_lines.append(diagnostic_cell("Inventory command failed without diagnostic output."))
    else:
        diagnostics_lines = [
            diagnostic_cell(line) for line in raw_diagnostics
            if line.startswith(DIAGNOSTIC_PREFIXES)
        ]
    repo_count = len({row["repo"] for row in references})

    lines = [
        "# Canonical changelog contract fleet report",
        "",
        f"Generated: `{markdown_cell(generated_at)}`",
        f"Inventory status: **{'complete' if inventory_status == 0 else 'incomplete'}**",
        f"References: {len(references)} across {repo_count} repositories.",
        "",
        f"## Drifted references ({len(drifted)})",
        "",
    ]
    if drifted:
        lines.extend(render_table(
            drifted,
            ("repo", "adopter_file", "upstream_path", "pinned_sha"),
            ("Repository", "Adopter file", "Contract path", "Pinned SHA"),
        ))
    else:
        lines.append("No drifted references were found.")

    lines.extend(["", f"## Unresolved references ({len(unknown)})", ""])
    if unknown:
        lines.extend(render_table(
            unknown,
            ("repo", "adopter_file", "upstream_path", "pinned_sha"),
            ("Repository", "Adopter file", "Contract path", "Pinned SHA"),
        ))
    else:
        lines.append("No unresolved references were found.")

    lines.extend(["", f"## Generated-header anomalies ({len(header_anomalies)})", ""])
    if header_anomalies:
        lines.extend(render_table(
            header_anomalies,
            ("repo", "adopter_file", "header_sha", "file_uses_sha", "header_invariant"),
            ("Repository", "Adopter file", "Header SHA", "Used SHAs", "Invariant"),
        ))
    else:
        lines.append("No generated-header anomalies were found.")

    lines.extend(["", "## Inventory diagnostics", ""])
    if diagnostics_lines:
        lines.extend(f"- `{line}`" for line in diagnostics_lines)
    else:
        lines.append("No incomplete-inventory diagnostics were reported.")

    lines.extend(["", f"Observed statuses: {', '.join(statuses) if statuses else 'none'}.", ""])
    return "\n".join(lines)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--inventory", required=True, type=Path)
    parser.add_argument("--diagnostics", required=True, type=Path)
    parser.add_argument("--generated-at", required=True)
    parser.add_argument("--inventory-status", required=True, type=int)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    try:
        report = render_report(
            args.inventory.read_text(),
            args.diagnostics.read_text(),
            args.generated_at,
            args.inventory_status,
        )
    except (OSError, ValueError) as error:
        print(f"fleet report: {error}", file=sys.stderr)
        return 1
    args.output.write_text(report)
    print(report)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
