#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
requirements="$root/scripts/actions-ci-changelog-release.requirements.txt"
dependency_dir="$(mktemp -d "${TMPDIR:-/tmp}/verjson-changelog-schema-test.XXXXXX")"
python="${CHANGELOG_SCHEMA_TEST_PYTHON:-python3}"
trap 'rm -rf -- "$dependency_dir"' EXIT

# Prove the test cannot fall back to a runner-provided package. The final test uses
# the same isolated interpreter, so removing acquisition makes its import fail.
if PYTHONPATH= "$python" -S -c 'import jsonschema' >/dev/null 2>&1; then
  printf 'jsonschema is unexpectedly importable without declared dependencies\n' >&2
  exit 1
fi

if ! "$python" -m pip --version >/dev/null 2>&1; then
  printf 'pip is required; actions-ci must provision it with setup-python\n' >&2
  exit 1
fi

"$python" -m pip install \
  --disable-pip-version-check \
  --no-input \
  --quiet \
  --no-deps \
  --only-binary=:all: \
  --require-hashes \
  --target "$dependency_dir" \
  --requirement "$requirements"

PYTHONNOUSERSITE=1 PYTHONPATH="$dependency_dir" \
  "$python" -S "$root/scripts/changelog-fragment-schema.test.py"
