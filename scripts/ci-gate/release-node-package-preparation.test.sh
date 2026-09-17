#!/usr/bin/env bash
# Exercise the actual node-release preparation block at the publish/pack boundary.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
workflow="$root/.github/workflows/node-release.yml"
work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT

prepare="$work/prepare.sh"
awk '
  /^      - name: Prepare release package metadata$/ { found = 1; next }
  found && /^        run: \|$/ { capture = 1; next }
  capture && /^      - / { exit }
  capture { sub(/^          /, ""); print }
' "$workflow" >"$prepare"
bash -n "$prepare"

prepare_line="$(grep -n -m1 'scripts/release-prepare-packages.sh "\$PACKAGE_VERSION"' "$workflow" | cut -d: -f1)"
pack_line="$(grep -n -m1 'npm pack "\$package_path" --json --ignore-scripts' "$workflow" | cut -d: -f1)"
[ -n "$prepare_line" ] && [ -n "$pack_line" ] && [ "$prepare_line" -lt "$pack_line" ] \
  || { echo "FAIL - preparation is not before script-disabled packing" >&2; exit 1; }

make_repo() {
  local destination="$1"
  mkdir -p "$destination/packages/cli-schema" "$destination/scripts"
  cat >"$destination/package.json" <<'EOF'
{"name":"release-fixture","version":"1.2.3"}
EOF
  cat >"$destination/packages/cli-schema/package.json" <<'EOF'
{"name":"@verjson/cli-schema","version":"1.2.3","files":["dist"]}
EOF
  cat >"$destination/scripts-placeholder" <<'EOF'
fixture
EOF
}

repo="$work/repo"
make_repo "$repo"
cat >"$repo/scripts/release-prepare-packages.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[ "${1-}" = 1.2.3 ]
[ "${NODE_AUTH_TOKEN+x}" != x ]
mkdir -p packages/cli-schema/dist
printf '%s\n' prepared > packages/cli-schema/dist/index.js
EOF
chmod +x "$repo/scripts/release-prepare-packages.sh"

( cd "$repo" && env -u NODE_AUTH_TOKEN REQUIRE_PACKAGE_PREPARATION=true PACKAGE_VERSION=1.2.3 bash -euo pipefail "$prepare" )
( cd "$repo" && env -u NODE_AUTH_TOKEN npm pack ./packages/cli-schema --json --ignore-scripts >pack.json )
tarball="$(find "$repo" -maxdepth 1 -name '*cli-schema-*.tgz' -print -quit)"
[ -n "$tarball" ] && tar -tzf "$tarball" | grep -q '^package/dist/index.js$' \
  || { echo "FAIL - prepared nested dist was absent from the script-disabled package" >&2; exit 1; }
echo "ok   - required publish preparation creates the nested dist before npm pack"

missing="$work/missing"
cp -a "$repo" "$missing"
rm "$missing/scripts/release-prepare-packages.sh" "$missing/"*.tgz "$missing/pack.json"
if ( cd "$missing" && env -u NODE_AUTH_TOKEN REQUIRE_PACKAGE_PREPARATION=true PACKAGE_VERSION=1.2.3 bash -euo pipefail "$prepare" ); then
  echo "FAIL - required preparation accepted an absent hook" >&2
  exit 1
fi
echo "ok   - required publish preparation fails closed when the hook is absent"

failing="$work/failing"
cp -a "$repo" "$failing"
cat >"$failing/scripts/release-prepare-packages.sh" <<'EOF'
#!/usr/bin/env bash
exit 19
EOF
chmod +x "$failing/scripts/release-prepare-packages.sh"
if ( cd "$failing" && env -u NODE_AUTH_TOKEN REQUIRE_PACKAGE_PREPARATION=true PACKAGE_VERSION=1.2.3 bash -euo pipefail "$prepare" ); then
  echo "FAIL - required preparation accepted a failed hook" >&2
  exit 1
fi
echo "ok   - required publish preparation propagates hook failure before packing"

root_default="$work/root-default"
make_repo "$root_default"
( cd "$root_default" && env -u NODE_AUTH_TOKEN REQUIRE_PACKAGE_PREPARATION=false PACKAGE_VERSION=1.2.3 bash -euo pipefail "$prepare" )
echo "ok   - root release default keeps absent preparation optional"
