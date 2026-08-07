#!/usr/bin/env bash
# Execute the migration guide's consumer adoption sequence end to end (#354).
set -uo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
guide="$root/docs/changelog/migration.md"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
consumer="$tmp/consumer"
sequence="$tmp/migrate.sh"

mkdir -p "$consumer/NEXT"
git -C "$consumer" init -q
git -C "$consumer" config user.name test
git -C "$consumer" config user.email test@example.com

cat >"$consumer/NEXT/2026-08-07-issue-354-migration-fixture.md" <<'EOF'
---
date: 2026-08-07
issue: 354
refs: 388
title: Exercise the documented migration
summary: Exercise every generated consumer artifact.
---

Disposable consumer fixture.
EOF
git -C "$consumer" add NEXT
git -C "$consumer" commit -qm fixture

awk '
  /<!-- executable-migration:start -->/ { capture = 1; next }
  /<!-- executable-migration:end -->/ { capture = 0 }
  capture && /^[[:space:]]*```bash[[:space:]]*$/ { in_bash = 1; next }
  capture && in_bash && /^[[:space:]]*```[[:space:]]*$/ { in_bash = 0; next }
  capture && in_bash { sub(/^   /, ""); print }
' "$guide" >"$sequence"

if [ ! -s "$sequence" ]; then
  echo "FAIL - migration guide has no machine-executable adoption sequence"
  exit 1
fi

if ! (
  cd "$consumer"
  CONTRACT_SOURCE_URL="$root" PUBLISH_NODE=true bash "$sequence"
) >"$tmp/sequence.out" 2>&1; then
  echo "FAIL - documented migration sequence failed"
  sed 's/^/diag - /' "$tmp/sequence.out"
  exit 1
fi

for artifact in \
  .github/workflows/changelog.yml \
  .github/workflows/release.yml \
  scripts/render-next.sh \
  scripts/changelog-contract.test.sh; do
  if [ ! -f "$consumer/$artifact" ]; then
    echo "FAIL - documented sequence did not generate $artifact"
    exit 1
  fi
done

for executable in scripts/render-next.sh scripts/changelog-contract.test.sh; do
  if [ ! -x "$consumer/$executable" ]; then
    echo "FAIL - documented sequence did not make $executable executable"
    exit 1
  fi
done

if ! bash "$consumer/scripts/changelog-contract.test.sh" >"$tmp/contract.out" 2>&1; then
  echo "FAIL - generated consumer contract, including its release-path dry run, failed"
  sed 's/^/diag - /' "$tmp/contract.out"
  exit 1
fi

if ! grep -qF "a real release produces exactly the state asserted above" "$tmp/contract.out"; then
  echo "FAIL - generated consumer contract did not exercise its release path"
  sed 's/^/diag - /' "$tmp/contract.out"
  exit 1
fi

echo "ok - exact migration sequence generates and validates a disposable consumer"
