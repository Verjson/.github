#!/usr/bin/env python3
"""Ensure relative links in ADR READMEs resolve to tracked files."""

import re
import subprocess
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
LINK = re.compile(r"\]\((?![a-z][a-z0-9+.-]*:|/)([^)#\s]+)(?:#[^)]*)?\)", re.IGNORECASE)


def main() -> int:
    tracked = {
        Path(path)
        for path in subprocess.check_output(
            ["git", "ls-files", "docs/decisions/*/README.md"], cwd=ROOT, text=True
        ).splitlines()
    }
    failures = []
    for relative in sorted(tracked):
        source = ROOT / relative
        for target in LINK.findall(source.read_text(encoding="utf-8")):
            resolved = (source.parent / target).resolve()
            try:
                resolved.relative_to(ROOT)
            except ValueError:
                failures.append(f"{relative}: link escapes repository: {target}")
                continue
            if not resolved.is_file():
                failures.append(f"{relative}: missing relative target: {target}")
    if failures:
        print("\n".join(failures))
        return 1
    print(f"ADR relative links valid ({len(tracked)} documents checked)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
