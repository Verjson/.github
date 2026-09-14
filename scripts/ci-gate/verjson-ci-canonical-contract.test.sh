#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
workflow="$root/.github/workflows/verjson-ci.yml"
adoption="$root/docs/verjson-ci-adoption.md"

python3 - "$workflow" "$adoption" <<'PY'
import re
import sys
from pathlib import Path

workflow_text = Path(sys.argv[1]).read_text(encoding="utf-8")
adoption_text = Path(sys.argv[2]).read_text(encoding="utf-8")


def validate(workflow: str, adoption: str) -> None:
    assert "on:\n  workflow_call:" in workflow
    assert "      image:\n" in workflow
    assert "        required: true\n" in workflow
    assert re.search(
        r"(?m)^    uses: Verjson/verjson-ci/\.github/workflows/reusable-ci\.yml@"
        r"[0-9a-f]{40}$",
        workflow,
    )
    assert not re.search(r"@(?:main|master|v[0-9]|latest)\b", workflow)
    assert "secrets:" not in workflow
    assert "github.token" not in workflow
    assert "GitHub organizations" in adoption
    assert "GitLab installations" in adoption
    assert "$CI_SERVER_FQDN/" in adoption
    assert "CI_PROJECT_ID" in adoption
    assert "GitHub token/OIDC" in adoption
    assert "GitLab job token/OIDC" in adoption


validate(workflow_text, adoption_text)
print("ok - package-backed adapter is immutable and credentialless")

mutants = {
    "mutable package ref": (
        workflow_text.replace(
            "@c9084daca387849c09f1d97bccf8ac311ff11615", "@main", 1
        ),
        adoption_text,
    ),
    "forwarded secrets": (workflow_text + "\nsecrets: inherit\n", adoption_text),
    "missing required image": (
        workflow_text.replace("        required: true\n", "        required: false\n", 1),
        adoption_text,
    ),
    "missing GitLab boundary": (
        workflow_text,
        adoption_text.replace("GitLab installations", "Other installations", 1),
    ),
}
for name, (workflow_mutant, adoption_mutant) in mutants.items():
    try:
        validate(workflow_mutant, adoption_mutant)
    except AssertionError:
        print(f"ok - {name} fails closed")
    else:
        raise AssertionError(f"{name} passed")
PY
