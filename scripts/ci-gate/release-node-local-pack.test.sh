#!/usr/bin/env bash
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$here/../.." && pwd)"
workflow="$repo_root/.github/workflows/node-release.yml"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

awk '
  /LOCAL_PACKAGE_PATH_BEGIN/ { active = 1; next }
  /LOCAL_PACKAGE_PATH_END/ { exit }
  active { sub(/^          /, ""); print }
' "$workflow" >"$work/local-path.sh"
pack_line="$(sed -n '/^            npm pack "\$package_path"/ { s/^            //; p; }' "$workflow")"
[ -n "$pack_line" ] || { echo "FAIL - reusable local npm pack command not found" >&2; exit 1; }
bash -n "$work/local-path.sh"

awk '
  /NPM_PACK_JSON_BEGIN/ { active = 1; next }
  /NPM_PACK_JSON_END/ { exit }
  active { sub(/^          /, ""); print }
' "$workflow" >"$work/parse-pack.js"

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
  node "$work/parse-pack.js" "$pack_json" "$expected_version" >"$work/package-meta.tsv"
  node - "$work/package-meta.tsv" "$expected_name" "$expected_version" "$work/repo" <<'NODE'
const fs = require("fs");
const path = require("path");
const [jsonPath, expectedName, expectedVersion, repo] = process.argv.slice(2);
const [name, version, integrity, filename] = fs.readFileSync(jsonPath, "utf8").trim().split("\t");
if (name !== expectedName || version !== expectedVersion) {
  throw new Error(`packed ${name}@${version}, expected ${expectedName}@${expectedVersion}`);
}
if (!integrity.startsWith("sha512-")) throw new Error("missing integrity");
const archive = path.join(repo, filename);
if (!fs.existsSync(archive)) throw new Error(`missing local archive ${archive}`);
NODE
}

cat >"$work/npm11.json" <<'JSON'
[{"name":"@fixture/pkg","version":"1.2.3","integrity":"sha512-fixture","filename":"fixture.tgz"}]
JSON
cat >"$work/npm12.json" <<'JSON'
{"@fixture/pkg":{"name":"@fixture/pkg","version":"1.2.3","integrity":"sha512-fixture","filename":"fixture.tgz"}}
JSON
for fixture in npm11 npm12; do
  [ "$(node "$work/parse-pack.js" "$work/$fixture.json" 1.2.3 | cut -f1)" = @fixture/pkg ]
done

cat >"$work/mismatched-key.json" <<'JSON'
{"@fixture/spoof":{"name":"@fixture/pkg","version":"1.2.3","integrity":"sha512-fixture","filename":"fixture.tgz"}}
JSON
if node "$work/parse-pack.js" "$work/mismatched-key.json" 1.2.3 >/dev/null 2>&1; then
  echo "FAIL - npm 12 object key did not have to match package metadata" >&2
  exit 1
fi
cat >"$work/multiple-keys.json" <<'JSON'
{"@fixture/pkg":{"name":"@fixture/pkg","version":"1.2.3","integrity":"sha512-fixture","filename":"fixture.tgz"},"@fixture/other":{"name":"@fixture/other","version":"1.2.3","integrity":"sha512-fixture","filename":"other.tgz"}}
JSON
if node "$work/parse-pack.js" "$work/multiple-keys.json" 1.2.3 >/dev/null 2>&1; then
  echo "FAIL - npm 12 object accepted more than one packed artifact" >&2
  exit 1
fi

pack_and_assert . @fixture/root 1.2.3
pack_and_assert compat @fixture/local-compat 9.8.7
echo "ok - reusable npm pack command resolves root and secondary packages locally with the registry unreachable"
