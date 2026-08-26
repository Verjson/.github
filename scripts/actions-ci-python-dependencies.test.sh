#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
requirements="$root/scripts/actions-ci-changelog-release.requirements.txt"
dependency_root="$(mktemp -d "${TMPDIR:-/tmp}/verjson-actions-ci-python.XXXXXX")"
python="${ACTIONS_CI_TEST_PYTHON:-python3}"
trap 'rm -rf -- "$dependency_root"' EXIT

"$python" -m venv "$dependency_root/venv"
isolated_python="$dependency_root/venv/bin/python"

if "$isolated_python" -I -c 'import jsonschema, yaml' >/dev/null 2>&1; then
  printf 'fresh Python unexpectedly inherited changelog-release dependencies\n' >&2
  exit 1
fi

"$isolated_python" -m pip install \
  --disable-pip-version-check \
  --no-input \
  --quiet \
  --no-deps \
  --only-binary=:all: \
  --require-hashes \
  --requirement "$requirements"

"$isolated_python" -I - <<'PY'
import importlib.metadata

expected = {"jsonschema": "4.25.1", "PyYAML": "6.0.3"}
actual = {name: importlib.metadata.version(name) for name in expected}
if actual != expected:
    raise SystemExit(f"installed dependency versions differ: {actual!r}")
PY

printf 'fresh Python acquires the hash-verified changelog-release dependencies\n'
