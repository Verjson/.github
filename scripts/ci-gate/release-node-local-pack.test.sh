#!/usr/bin/env bash
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$here/../.." && pwd)"
generator="$repo_root/scripts/gen-changelog-caller.sh"
sha="$(git -C "$repo_root" rev-parse HEAD)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

bash "$generator" release-node "$sha" --scope @fixture --package-dir compat >"$work/release.yml"
awk '
  /LOCAL_PACKAGE_PATH_BEGIN/ { active = 1; next }
  /LOCAL_PACKAGE_PATH_END/ { exit }
  active { sub(/^          /, ""); print }
' "$work/release.yml" >"$work/local-path.sh"
pack_line="$(sed -n '/^            npm pack "\$package_path"/ { s/^            //; p; }' "$work/release.yml")"
[ -n "$pack_line" ] || { echo "FAIL - generated local npm pack command not found" >&2; exit 1; }
bash -n "$work/local-path.sh"

mkdir -p "$work/repo/compat"
cat >"$work/repo/package.json" <<'JSON'
{"name":"@fixture/root","version":"1.2.3"}
JSON
cat >"$work/repo/compat/package.json" <<'JSON'
{"name":"@fixture/local-compat","version":"9.8.7"}
JSON

pack_and_assert() {
  local package_dir="$1" expected_name="$2" expected_version="$3"
  local pack_json="$work/$package_dir-pack.json"
  (
    cd "$work/repo"
    source "$work/local-path.sh"
    export npm_config_registry=http://127.0.0.1:9
    export npm_config_fetch_retries=0
    eval "$pack_line"
  )
  node - "$pack_json" "$expected_name" "$expected_version" "$work/repo" <<'NODE'
const fs = require("fs");
const path = require("path");
const [jsonPath, expectedName, expectedVersion, repo] = process.argv.slice(2);
const result = JSON.parse(fs.readFileSync(jsonPath, "utf8"));
if (!Array.isArray(result) || result.length !== 1) throw new Error("expected one packed artifact");
const item = result[0];
if (item.name !== expectedName || item.version !== expectedVersion) {
  throw new Error(`packed ${item.name}@${item.version}, expected ${expectedName}@${expectedVersion}`);
}
const archive = path.join(repo, item.filename);
if (!fs.existsSync(archive)) throw new Error(`missing local archive ${archive}`);
NODE
}

pack_and_assert . @fixture/root 1.2.3
pack_and_assert compat @fixture/local-compat 9.8.7
echo "ok - generated npm pack command resolves root and secondary packages locally with the registry unreachable"
