#!/usr/bin/env python3
"""Render canonical #731 adopter instructions from reviewed repository data."""

from __future__ import annotations

import argparse
import json
import re
from pathlib import Path


def recommended_pin(root: Path) -> str:
    readme = (root / "docs/changelog/README.md").read_text(encoding="utf-8")
    pins = re.findall(r"^<!-- recommended-contract-pin: ([0-9a-f]{40}) -->$", readme, re.MULTILINE)
    if len(pins) != 1:
        raise ValueError("README must expose exactly one recommended contract pin")
    floors = json.loads((root / "config/capability-floors.json").read_text(encoding="utf-8"))
    changelog = [item for item in floors["capabilities"] if "scripts/gen-changelog-caller.sh" in item["generators"]]
    if not changelog:
        raise ValueError("capability registry has no changelog generator floors")
    return pins[0]


def render(repository: str, root: Path) -> str:
    if re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repository) is None:
        raise ValueError("repository must be OWNER/NAME")
    pin = recommended_pin(root)
    return f"""Adopt the canonical changelog contract in `{repository}` at immutable contract SHA `{pin}`.

Generate, never hand-edit, all four required artifacts from that same checkout:

```sh
scripts/gen-changelog-caller.sh generated-artifacts \"{pin}\" > .github/workflows/changelog.yml
scripts/gen-changelog-caller.sh renderer \"{pin}\" > scripts/render-next.sh
scripts/gen-changelog-caller.sh contract-test \"{pin}\" > scripts/changelog-contract.test.sh
scripts/gen-changelog-caller.sh pr-gate \"{pin}\" > .github/workflows/changelog-contract.yml
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
