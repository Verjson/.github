#!/usr/bin/env python3
import json
import re
import sys


LOCKFILE = re.compile(
    r"(^|/)(package-lock\.json|npm-shrinkwrap\.json|pnpm-lock\.yaml|yarn\.lock|"
    r"bun\.lockb?|Cargo\.lock|go\.sum|poetry\.lock|composer\.lock|"
    r"gradle\.lockfile|Gemfile\.lock)$",
    re.IGNORECASE,
)
AGENT_INSTRUCTION = re.compile(
    r"(^|/)(CLAUDE|AGENTS|GEMINI|CURSOR|OPENCODE)\.md$|"
    r"(^|/)(SKILL|PROMPT|INSTRUCTIONS)\.md$|"
    r"(^|/)(rules?|skills?|prompts?)/|"
    r"(^|/)[^/]*(agent|copilot)?[-_ ]?instructions?[^/]*\.md$|"
    r"(^|/)[^/]*prompt[^/]*\.md$",
    re.IGNORECASE,
)
COMMUNITY_FILE = re.compile(
    r"(^NEXT(\.md|/[^/]+\.md)$|(^|/)(README(\.[^/]*)?|CHANGELOG(\.[^/]*)?|"
    r"CONTRIBUTING(\.[^/]*)?|CODE_OF_CONDUCT(\.[^/]*)?|SECURITY(\.[^/]*)?|"
    r"SUPPORT(\.[^/]*)?|LICENSE(\.[^/]*)?|\.github/(ISSUE_TEMPLATE/.*|"
    r"PULL_REQUEST_TEMPLATE\.md|FUNDING\.yml))$)",
    re.IGNORECASE,
)


def load_files() -> list[dict[str, str]]:
    payload = json.load(sys.stdin)
    if not isinstance(payload, list):
        raise ValueError("file payload must be an array")
    files: list[dict[str, str]] = []
    for entry in payload:
        if not isinstance(entry, dict):
            raise ValueError("each file must be an object")
        filename = entry.get("filename")
        status = entry.get("status")
        if not isinstance(filename, str) or not filename or not isinstance(status, str) or not status:
            raise ValueError("each file requires non-empty filename and status strings")
        files.append({"filename": filename, "status": status})
    return files


def is_non_agent_documentation(filename: str) -> bool:
    if AGENT_INSTRUCTION.search(filename):
        return False
    if re.search(r"(^|/)NEXT/.+/.+\.md$|.+/NEXT/[^/]+\.md$", filename, re.IGNORECASE):
        return False
    return filename.lower().endswith(".md") or bool(COMMUNITY_FILE.search(filename))


def classify(files: list[dict[str, str]]) -> dict[str, str]:
    if not files:
        return {"lane": "fast", "reason": "empty diff; no reviewable patch"}
    filenames = [entry["filename"] for entry in files]
    if all(LOCKFILE.search(filename) for filename in filenames):
        return {
            "lane": "fast",
            "reason": "generated lockfile-only change; deterministic integrity and CI are authoritative",
        }
    if all(is_non_agent_documentation(filename) for filename in filenames):
        return {
            "lane": "fast",
            "reason": f"non-agent documentation/community-health-only change ({len(files)} file(s))",
        }
    return {
        "lane": "ai",
        "reason": "code, executable policy, dependency manifest, or agent-instruction change requires AI review",
    }


def main() -> int:
    try:
        print(json.dumps(classify(load_files()), separators=(",", ":")))
    except (json.JSONDecodeError, OSError, TypeError, ValueError) as error:
        print(f"review classification failed closed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
