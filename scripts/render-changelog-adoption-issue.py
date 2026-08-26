#!/usr/bin/env python3
"""Render canonical #731 adopter instructions from reviewed repository data."""

from __future__ import annotations

import argparse
import json
import re
import subprocess
from pathlib import Path

CHANGELOG_GENERATOR = "scripts/gen-changelog-caller.sh"
SHA_PATTERN = re.compile(r"^[0-9a-f]{40}$")


def _git(root: Path, *args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["git", "-C", str(root), *args],
        capture_output=True,
        text=True,
        check=False,
    )


def _is_shallow(root: Path) -> bool:
    result = _git(root, "rev-parse", "--is-shallow-repository")
    if result.returncode != 0:
        raise ValueError(f"cannot inspect changelog contract history: {result.stderr.strip()}")
    return result.stdout.strip() == "true"


def _has_commit(root: Path, sha: str) -> bool:
    return _git(root, "cat-file", "-e", f"{sha}^{{commit}}").returncode == 0


def _fetch_commit(root: Path, sha: str, depth: int) -> bool:
    result = _git(root, "fetch", "--quiet", "--no-tags", f"--depth={depth}", "origin", sha)
    return result.returncode == 0 and _has_commit(root, sha)


def _descends(root: Path, floor: str, pin: str) -> bool:
    for sha in (floor, pin):
        if not _has_commit(root, sha) and not _fetch_commit(root, sha, 1):
            raise ValueError(f"changelog contract commit {sha} is not available")

    result = _git(root, "merge-base", "--is-ancestor", floor, pin)
    if result.returncode == 0:
        return True
    if result.returncode not in (0, 1):
        raise ValueError(f"cannot compare changelog contract commits: {result.stderr.strip()}")
    if not _is_shallow(root):
        return False

    for depth in (64, 256, 1024, 4096):
        if not _fetch_commit(root, pin, depth):
            break
        result = _git(root, "merge-base", "--is-ancestor", floor, pin)
        if result.returncode == 0:
            return True
        if result.returncode not in (0, 1):
            raise ValueError(f"cannot compare changelog contract commits: {result.stderr.strip()}")
    return False


def recommended_pin(root: Path) -> str:
    registry = json.loads((root / "config/capability-floors.json").read_text(encoding="utf-8"))
    recommendations = registry.get("recommended_pins")
    if not isinstance(recommendations, dict):
        raise ValueError("capability registry has no recommended_pins map")
    pin = recommendations.get(CHANGELOG_GENERATOR)
    if not isinstance(pin, str) or SHA_PATTERN.fullmatch(pin) is None:
        raise ValueError("capability registry changelog recommendation must be a full commit SHA")

    changelog = [
        item
        for item in registry.get("capabilities", [])
        if CHANGELOG_GENERATOR in item.get("generators", [])
    ]
    if not changelog:
        raise ValueError("capability registry has no changelog generator floors")
    for item in changelog:
        floor = item.get("introduced_at")
        if not isinstance(floor, str) or SHA_PATTERN.fullmatch(floor) is None:
            raise ValueError("capability registry changelog floor must be a full commit SHA")
        if not _descends(root, floor, pin):
            raise ValueError(f"recommended changelog pin {pin} predates capability floor {floor}")
    return pin


def render(repository: str, root: Path) -> str:
    if re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repository) is None:
        raise ValueError("repository must be OWNER/NAME")
    pin = recommended_pin(root)
    return f"""Adopt the canonical changelog contract in `{repository}` at immutable contract SHA `{pin}`.

Generate, never hand-edit, all four required artifacts from that same checkout:

```bash
set -euo pipefail
PIN={pin}
CONTRACT_SOURCE_URL="${{CONTRACT_SOURCE_URL:-https://github.com/Verjson/.github.git}}"
CONSUMER_ROOT="$(git rev-parse --show-toplevel)"
CONTRACT_ROOT="$(mktemp -d)"
cleanup_contract_checkout() {{ rm -rf -- "$CONTRACT_ROOT"; }}
trap cleanup_contract_checkout EXIT

git -C "$CONTRACT_ROOT" init -q
git -C "$CONTRACT_ROOT" fetch --quiet --depth=1 "$CONTRACT_SOURCE_URL" "$PIN"
git -C "$CONTRACT_ROOT" checkout --quiet --detach FETCH_HEAD
test "$(git -C "$CONTRACT_ROOT" rev-parse HEAD)" = "$PIN"

cd "$CONSUMER_ROOT"
mkdir -p .github/workflows scripts
"$CONTRACT_ROOT/scripts/gen-changelog-caller.sh" workflow "$PIN" \
  > .github/workflows/changelog.yml
"$CONTRACT_ROOT/scripts/gen-changelog-caller.sh" renderer "$PIN" \
  > scripts/render-next.sh
"$CONTRACT_ROOT/scripts/gen-changelog-caller.sh" contract-test "$PIN" \
  > scripts/changelog-contract.test.sh
"$CONTRACT_ROOT/scripts/gen-changelog-caller.sh" pr-gate "$PIN" \
  > .github/workflows/changelog-contract.yml
chmod +x scripts/render-next.sh scripts/changelog-contract.test.sh
```

Preserve the required reusable-workflow context `changelog / validate`. The standalone generated PR gate publishes `changelog-contract`. Do not require the obsolete `generated-artifacts / validate` context.
"""


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("repository")
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1])
    args = parser.parse_args()
    print(render(args.repository, args.root), end="")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
