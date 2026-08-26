#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
requirements="$root/scripts/changelog-fragment-schema.requirements.txt"
dependency_dir="$(mktemp -d "${TMPDIR:-/tmp}/verjson-changelog-schema-test.XXXXXX")"
trap 'rm -rf -- "$dependency_dir"' EXIT

# Prove the test cannot fall back to a runner-provided package. The final test uses
# the same isolated interpreter, so removing acquisition makes its import fail.
if PYTHONPATH= python3 -S -c 'import jsonschema' >/dev/null 2>&1; then
  printf 'jsonschema is unexpectedly importable without declared dependencies\n' >&2
  exit 1
fi

python3 -m pip install \
  --disable-pip-version-check \
  --no-input \
  --quiet \
  --no-deps \
  --only-binary=:all: \
  --target "$dependency_dir" \
  --requirement "$requirements"

PYTHONNOUSERSITE=1 PYTHONPATH="$dependency_dir" \
  python3 -S "$root/scripts/changelog-fragment-schema.test.py"
