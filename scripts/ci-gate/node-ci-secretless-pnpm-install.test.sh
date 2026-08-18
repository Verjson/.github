#!/usr/bin/env bash
set -uo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
workflow="$root/.github/workflows/node-ci.yml"
fixture="$(mktemp -d)"
failures=0
trap 'rm -rf "$fixture"' EXIT

pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'not ok - %s\n' "$1" >&2; failures=$((failures + 1)); }

rewrite="$fixture/rewrite.py"
cleanup="$fixture/cleanup.sh"
python3 - "$workflow" "$rewrite" "$cleanup" <<'PY'
import sys
import yaml

document = yaml.safe_load(open(sys.argv[1], encoding="utf-8"))
install = next(
    step
    for step in document["jobs"]["build-test"]["steps"]
    if step.get("name") == "Install from verified secretless npm cache"
)["run"]
marker = 'PNPM_IMPORT_MAP="$PNPM_IMPORT_MAP" python3 - <<\'PY\'\n'
source = install.split(marker, 1)[1].split("\nPY\n", 1)[0]
open(sys.argv[2], "w", encoding="utf-8").write(source + "\n")
cleanup = install.split("cleanup() {", 1)[1].split("trap cleanup EXIT", 1)[0]
open(sys.argv[3], "w", encoding="utf-8").write(
    "set -euo pipefail\ncleanup() {" + cleanup + "trap cleanup EXIT\nfalse\n"
)
PY

package_dir="$fixture/package"
app_dir="$fixture/app"
mkdir -p "$package_dir" "$app_dir"
printf '%s\n' '{"name":"@verjson/contracts","version":"1.2.3","files":["index.js"]}' > "$package_dir/package.json"
printf '%s\n' 'module.exports = "fixture";' > "$package_dir/index.js"
(cd "$package_dir" && npm pack --silent --pack-destination "$fixture" >/dev/null)
tarball="$fixture/verjson-contracts-1.2.3.tgz"
printf '%s\n' '{"name":"secretless-fixture","version":"1.0.0","packageManager":"pnpm@11.22.0","dependencies":{"@verjson/contracts":"file:../verjson-contracts-1.2.3.tgz"}}' > "$app_dir/package.json"
(cd "$app_dir" && corepack pnpm install --lockfile-only --ignore-scripts >/dev/null)

digest="$(sha512sum "$tarball" | cut -d' ' -f1)"
python3 - "$app_dir/pnpm-lock.yaml" <<'PY'
import sys
import yaml

path = sys.argv[1]
document = yaml.safe_load(open(path, encoding="utf-8"))
package = next(iter(document["packages"].values()))
package["resolution"]["tarball"] = "https://npm.pkg.github.com/download/@verjson/contracts/1.2.3/fixture"
text = yaml.safe_dump(document, sort_keys=False)
text += """x-preservation:
  yes: no
  0123: 0123
  1:20: 1:20
  ~: ~
  2026-08-18: 2026-08-18
  1.20: 1.20
"""
open(path, "w", encoding="utf-8").write(text)
PY
original="$fixture/original.yaml"
cp -- "$app_dir/pnpm-lock.yaml" "$original"
sed -n '/^x-preservation:/,$p' "$original" > "$fixture/preservation.original"
mapping="$fixture/import-map.tsv"
printf '%s\t%s\n' "$digest" "$tarball" > "$mapping"
store="$fixture/store"
corepack pnpm store add --store-dir "$store" "$tarball" >/dev/null

if (cd "$app_dir" && PNPM_IMPORT_MAP="$mapping" python3 "$rewrite" \
    && corepack pnpm install --frozen-lockfile --ignore-scripts --prefer-offline --offline --store-dir "$store" >/dev/null); then
  pass "rewritten private tarball completes a real credentialless frozen pnpm install"
else
  fail "rewritten private tarball did not complete a real frozen pnpm install"
fi

if python3 - "$original" "$app_dir/pnpm-lock.yaml" "$tarball" <<'PY'
import json
import sys
from pathlib import Path

before = Path(sys.argv[1]).read_text(encoding="utf-8")
after = Path(sys.argv[2]).read_text(encoding="utf-8")
registry = "https://npm.pkg.github.com/download/@verjson/contracts/1.2.3/fixture"
replacement = json.dumps(Path(sys.argv[3]).resolve().as_uri())
assert before.count(registry) == 1
assert before.replace(registry, replacement, 1) == after
PY
then
  pass "the private tarball scalar is the rewrite's sole byte delta"
else
  fail "the rewrite changed bytes outside the private tarball scalar"
fi

sed -n '/^x-preservation:/,$p' "$app_dir/pnpm-lock.yaml" > "$fixture/preservation.rewritten"
if cmp -s "$fixture/preservation.original" "$fixture/preservation.rewritten"; then
  pass "non-JSON YAML scalars and keys remain byte-identical after the rewrite"
else
  fail "the rewrite mangled an unrelated YAML scalar or key"
fi

for unsafe_yaml in alias tag; do
  cp -- "$original" "$app_dir/pnpm-lock.yaml"
  if [ "$unsafe_yaml" = alias ]; then
    sed -i '1i x-anchor: &private https://npm.pkg.github.com/download/@verjson/contracts/1.2.3/fixture' "$app_dir/pnpm-lock.yaml"
    sed -i '/tarball:/ s#https://npm.pkg.github.com/download/@verjson/contracts/1.2.3/fixture#*private#' "$app_dir/pnpm-lock.yaml"
  else
    sed -i 's#https://npm.pkg.github.com/download/@verjson/contracts/1.2.3/fixture#!private https://npm.pkg.github.com/download/@verjson/contracts/1.2.3/fixture#' "$app_dir/pnpm-lock.yaml"
  fi
  cp -- "$app_dir/pnpm-lock.yaml" "$fixture/$unsafe_yaml.original"
  if (cd "$app_dir" && PNPM_IMPORT_MAP="$mapping" python3 "$rewrite") >"$fixture/$unsafe_yaml.out" 2>&1; then
    fail "rewrite accepted a YAML $unsafe_yaml"
  elif grep -qF 'rejects YAML aliases, anchors, and tags' "$fixture/$unsafe_yaml.out" \
      && cmp -s "$fixture/$unsafe_yaml.original" "$app_dir/pnpm-lock.yaml"; then
    pass "YAML $unsafe_yaml is rejected without modifying the lockfile"
  else
    fail "YAML $unsafe_yaml rejection was not fail-closed"
  fi
done

cp -- "$original" "$app_dir/pnpm-lock.yaml"
: > "$mapping"
if (cd "$app_dir" && PNPM_IMPORT_MAP="$mapping" python3 "$rewrite") >"$fixture/missing.out" 2>&1; then
  fail "rewrite accepted a missing verified transfer mapping"
elif cmp -s "$original" "$app_dir/pnpm-lock.yaml"; then
  pass "missing mapping fails without modifying the lockfile"
else
  fail "missing mapping failure modified the lockfile"
fi

cp -- "$original" "$app_dir/pnpm-lock.yaml"
surplus="$(printf '0%.0s' {1..128})"
printf '%s\t%s\n%s\t%s\n' "$digest" "$tarball" "$surplus" "$tarball" > "$mapping"
if (cd "$app_dir" && PNPM_IMPORT_MAP="$mapping" python3 "$rewrite") >"$fixture/surplus.out" 2>&1; then
  fail "rewrite accepted a surplus transfer mapping"
elif grep -qF "$surplus" "$fixture/surplus.out" && cmp -s "$original" "$app_dir/pnpm-lock.yaml"; then
  pass "surplus mapping reports its safe digest and leaves the lockfile unchanged"
else
  fail "surplus mapping did not report its digest or modified the lockfile"
fi

cp -- "$original" "$app_dir/pnpm-lock.yaml"
printf '%s\t%s\n' "$digest" "$tarball" > "$mapping"
(cd "$app_dir" && PNPM_IMPORT_MAP="$mapping" python3 "$rewrite")
cleanup_cache="$fixture/cleanup-cache"
cleanup_transfer="$fixture/cleanup-transfer"
mkdir -p "$cleanup_cache" "$cleanup_transfer" "$store"
cp -- "$original" "$store/pnpm-lock.original.yaml"
(cd "$app_dir" && \
  SECRETLESS_CACHE_DIR="$cleanup_cache" PNPM_STORE_DIR="$store" TRANSFER_DIR="$cleanup_transfer" \
  bash "$cleanup") >/dev/null 2>&1 || true
if cmp -s "$original" "$app_dir/pnpm-lock.yaml"; then
  pass "failure after rewriting restores the original lockfile"
else
  fail "failure after rewriting left a mutated lockfile"
fi

exit "$failures"
