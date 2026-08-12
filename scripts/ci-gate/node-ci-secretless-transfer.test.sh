#!/usr/bin/env bash
set -uo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
workflow="$root/.github/workflows/node-ci.yml"
failures=0
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'not ok - %s\n' "$1" >&2; failures=$((failures + 1)); }

python3 - "$workflow" <<'PY' \
  && pass "secretless transfer is exact-attempt, bounded, credentialless, and separately cleaned" \
  || fail "secretless transfer workflow structure violates its storage or trust contract"
import sys
import yaml

doc = yaml.safe_load(open(sys.argv[1], encoding="utf-8"))
jobs = doc["jobs"]
acquire = jobs["acquire-secretless-dependencies"]
build = jobs["build-test"]
cleanup = jobs["cleanup-secretless-transfer"]

assert acquire["outputs"]["transfer-artifact-id"] == "${{ steps.upload-secretless-transfer.outputs.artifact-id }}"
upload = next(step for step in acquire["steps"] if step.get("id") == "upload-secretless-transfer")
assert upload["with"]["name"] == "secretless-npm-cache-${{ github.run_id }}-${{ github.run_attempt }}"
assert upload["with"]["retention-days"] == 1
assert upload["with"]["compression-level"] == 0
assert "node_modules" not in upload["with"]["path"]

package = next(step for step in acquire["steps"] if step.get("name") == "Package bounded credential-free npm cache")
assert package["env"]["MAX_PAYLOAD_BYTES"] == "83886080"
assert package["env"]["NPM_CONFIG_GLOBALCONFIG"].startswith("${{ runner.temp }}/")
assert package["env"]["NPM_CONFIG_USERCONFIG"].startswith("${{ runner.temp }}/")
assert "_cacache" in package["run"]
assert "payload_bytes" in package["run"]
assert "run_attempt=$RUN_ATTEMPT" in package["run"]
assert "lock_sha256=$lock_sha256" in package["run"]
acquire_cleanup = next(step for step in acquire["steps"] if step.get("name") == "Remove local acquisition and transfer state")
assert acquire_cleanup["if"] == "always()"

download = next(step for step in build["steps"] if str(step.get("uses", "")).startswith("actions/download-artifact@"))
assert download["with"]["name"] == upload["with"]["name"]
install = next(step for step in build["steps"] if step.get("name") == "Install from verified secretless npm cache")
setup_index = next(index for index, step in enumerate(build["steps"]) if str(step.get("uses", "")).startswith("actions/setup-node@"))
setup = build["steps"][setup_index]
install_index = build["steps"].index(install)
assert setup_index < install_index
assert "!inputs.secretless-pr" in setup["with"]["cache"]
for credential in (
    "GH_TOKEN", "GITHUB_TOKEN", "NODE_AUTH_TOKEN", "NPM_TOKEN",
    "AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY", "AWS_SESSION_TOKEN",
    "GOOGLE_APPLICATION_CREDENTIALS", "AZURE_CREDENTIALS",
    "ACTIONS_ID_TOKEN_REQUEST_TOKEN", "ACTIONS_ID_TOKEN_REQUEST_URL",
):
    assert install["env"][credential] == ""
assert install["env"]["MAX_PAYLOAD_BYTES"] == package["env"]["MAX_PAYLOAD_BYTES"]
assert install["env"]["NPM_CONFIG_CACHE"].startswith("${{ runner.temp }}/secretless-runtime-cache-")
assert install["env"]["NPM_CONFIG_GLOBALCONFIG"].startswith("${{ runner.temp }}/")
assert install["env"]["NPM_CONFIG_USERCONFIG"].startswith("${{ runner.temp }}/")
assert "npm ci --offline --ignore-scripts --no-audit --no-fund" in install["run"]
assert "manifest_run_attempt" in install["run"]
assert "manifest_lock_sha256" in install["run"]
assert "manifest_payload_sha256" in install["run"]
build_cleanup = next(step for step in build["steps"] if step.get("name") == "Remove local secretless transfer state")
assert "always()" in build_cleanup["if"]
assert "needs.eligibility.outputs.should-run != 'false'" in build_cleanup["if"]
runtime_cleanup = next(step for step in build["steps"] if step.get("name") == "Remove job-scoped secretless runtime cache")
assert "always()" in runtime_cleanup["if"]
assert "inputs.secretless-pr" in runtime_cleanup["if"]

assert cleanup["needs"] == ["eligibility", "acquire-secretless-dependencies", "build-test"]
assert cleanup["if"].startswith("always() && inputs.secretless-pr")
assert cleanup["timeout-minutes"] == 5
assert cleanup["permissions"] == {"actions": "write"}
assert not any(str(step.get("uses", "")).startswith("actions/checkout@") for step in cleanup["steps"])
delete = cleanup["steps"][0]
assert delete["env"]["EXPECTED_NAME"] == upload["with"]["name"]
assert delete["env"]["GH_TOKEN"] == "${{ github.token }}"
assert ".workflow_run.id == $run_id" in delete["run"]
assert "actions/artifacts/$ARTIFACT_ID" in delete["run"]

for command in ("npm run build", "npm run typecheck --if-present", "npm test", "npm run lint --if-present"):
    step = next(step for step in build["steps"] if step.get("run") == command)
    assert "secrets." not in str(step.get("env", {}))
PY

python3 - "$workflow" "$tmp" <<'PY'
import sys
import yaml

doc = yaml.safe_load(open(sys.argv[1], encoding="utf-8"))
root = sys.argv[2]
names = {
    "Package bounded credential-free npm cache": "package.sh",
    "Install from verified secretless npm cache": "install.sh",
    "Delete exact run-attempt transfer artifact": "delete.sh",
}
for job in doc["jobs"].values():
    for step in job.get("steps", []):
        name = step.get("name")
        if name in names:
            with open(f"{root}/{names[name]}", "w", encoding="utf-8") as stream:
                stream.write(step["run"])
PY

mkdir -p "$tmp/bin" "$tmp/acquire/cache/_cacache/content-v2/sha512/aa" "$tmp/acquire/node_modules"
printf 'cached package bytes\n' > "$tmp/acquire/cache/_cacache/content-v2/sha512/aa/blob"
printf '%s\n' '{"name":"fixture","version":"1.0.0","lockfileVersion":3,"packages":{"":{"name":"fixture","version":"1.0.0"}}}' \
  > "$tmp/acquire/package-lock.json"
printf '%s\n' '#!/usr/bin/env bash' 'printf '\''%s\n'\'' "$*" >> "$NPM_STUB_LOG"' > "$tmp/bin/npm"
chmod +x "$tmp/bin/npm"

if (cd "$tmp/acquire" && PATH="$tmp/bin:$PATH" NPM_STUB_LOG="$tmp/npm.log" \
    CACHE_DIR="$tmp/acquire/cache" TRANSFER_DIR="$tmp/acquire/transfer" \
    NPM_CONFIG_GLOBALCONFIG="$tmp/acquire/empty-global.npmrc" \
    NPM_CONFIG_USERCONFIG="$tmp/acquire/empty-user.npmrc" \
    MAX_PAYLOAD_BYTES=83886080 RUN_ID=7001 RUN_ATTEMPT=3 bash "$tmp/package.sh") \
    && [ ! -d "$tmp/acquire/node_modules" ] \
    && grep -qFx 'run_id=7001' "$tmp/acquire/transfer/manifest" \
    && grep -qFx 'run_attempt=3' "$tmp/acquire/transfer/manifest" \
    && grep -qFx 'cache verify --cache '"$tmp/acquire/cache" "$tmp/npm.log"; then
  pass "packaging removes node_modules and binds the cache to run, attempt, lock, digest, and size"
else
  fail "packaging did not produce the bounded identity-bound cache transfer"
fi

mkdir -p "$tmp/oversize/cache/_cacache" "$tmp/oversize/node_modules"
printf '%2048s' x > "$tmp/oversize/cache/_cacache/blob"
cp "$tmp/acquire/package-lock.json" "$tmp/oversize/package-lock.json"
if (cd "$tmp/oversize" && PATH="$tmp/bin:$PATH" NPM_STUB_LOG="$tmp/npm.log" \
    CACHE_DIR="$tmp/oversize/cache" TRANSFER_DIR="$tmp/oversize/transfer" \
    NPM_CONFIG_GLOBALCONFIG="$tmp/oversize/empty-global.npmrc" \
    NPM_CONFIG_USERCONFIG="$tmp/oversize/empty-user.npmrc" \
    MAX_PAYLOAD_BYTES=1024 RUN_ID=7001 RUN_ATTEMPT=3 bash "$tmp/package.sh") >/dev/null 2>&1; then
  fail "a cache over the declared transfer budget was packaged"
else
  pass "a cache over the declared transfer budget fails before upload"
fi

run_install() {
  local fixture="$1" run_id="${2:-7001}" run_attempt="${3:-3}"
  (cd "$fixture" && PATH="$tmp/bin:$PATH" NPM_STUB_LOG="$fixture/npm.log" \
    GITHUB_ENV="$fixture/github.env" NPM_CONFIG_USERCONFIG="$fixture/empty.npmrc" \
    NPM_CONFIG_CACHE="$fixture/runtime-cache" \
    NPM_CONFIG_GLOBALCONFIG="$fixture/empty-global.npmrc" \
    SECRETLESS_CACHE_DIR="$fixture/build-cache" TRANSFER_DIR="$fixture/transfer" \
    MAX_PAYLOAD_BYTES=83886080 RUN_ID="$run_id" RUN_ATTEMPT="$run_attempt" \
    bash "$tmp/install.sh")
}

mkdir -p "$tmp/build"
cp "$tmp/acquire/package-lock.json" "$tmp/build/package-lock.json"
cp -R "$tmp/acquire/transfer" "$tmp/build/transfer"
if run_install "$tmp/build" \
    && grep -qF 'ci --offline --ignore-scripts --no-audit --no-fund --cache ' "$tmp/build/npm.log" \
    && [ ! -e "$tmp/build/transfer" ] && [ ! -e "$tmp/build/build-cache" ] \
    && grep -qFx 'NODE_AUTH_TOKEN=' "$tmp/build/github.env" \
    && grep -qFx 'npm_config_cache='"$tmp/build/runtime-cache" "$tmp/build/github.env" \
    && grep -qFx 'ACTIONS_ID_TOKEN_REQUEST_TOKEN=' "$tmp/build/github.env"; then
  pass "a matching transfer installs offline and scrubs credentials and local transfer state"
else
  fail "the credentialless offline install did not consume and clean a valid transfer"
fi

for mutation in attempt lock digest; do
  fixture="$tmp/reject-$mutation"
  mkdir -p "$fixture"
  cp "$tmp/acquire/package-lock.json" "$fixture/package-lock.json"
  cp -R "$tmp/acquire/transfer" "$fixture/transfer"
  case "$mutation" in
    attempt) run_id=7001; run_attempt=4 ;;
    lock) printf '\n' >> "$fixture/package-lock.json"; run_id=7001; run_attempt=3 ;;
    digest) printf 'tamper\n' >> "$fixture/transfer/npm-cache.tar"; run_id=7001; run_attempt=3 ;;
  esac
  if run_install "$fixture" "$run_id" "$run_attempt" >/dev/null 2>&1 || [ -e "$fixture/npm.log" ]; then
    fail "a transfer with a mismatched $mutation identity reached npm"
  else
    pass "a transfer with a mismatched $mutation identity fails before npm"
  fi
done

printf '%s\n' '#!/usr/bin/env bash' \
  'if [ "$1 $2" = "api --method" ]; then printf '\''%s\n'\'' "$*" >> "$GH_STUB_LOG"; exit 0; fi' \
  'printf '\''%s\n'\'' "$*" >> "$GH_STUB_LOG"' \
  'cat "$GH_ARTIFACT_METADATA"' \
  > "$tmp/bin/gh"
chmod +x "$tmp/bin/gh"
printf '%s\n' '{"id":9001,"name":"secretless-npm-cache-7001-3","expired":false,"workflow_run":{"id":7001}}' \
  > "$tmp/artifact.json"

if PATH="$tmp/bin:$PATH" GH_STUB_LOG="$tmp/gh.log" GH_ARTIFACT_METADATA="$tmp/artifact.json" \
    ARTIFACT_ID=9001 EXPECTED_NAME=secretless-npm-cache-7001-3 GH_TOKEN=token RUN_ID=7001 \
    GITHUB_REPOSITORY=Verjson/example bash "$tmp/delete.sh" \
    && grep -qFx 'api --method DELETE repos/Verjson/example/actions/artifacts/9001' "$tmp/gh.log"; then
  pass "cleanup verifies and deletes only the exact run artifact id"
else
  fail "cleanup did not delete the exact verified run artifact"
fi

printf '%s\n' '{"id":9001,"name":"secretless-npm-cache-7001-2","expired":false,"workflow_run":{"id":7001}}' \
  > "$tmp/wrong-artifact.json"
: > "$tmp/wrong-gh.log"
if PATH="$tmp/bin:$PATH" GH_STUB_LOG="$tmp/wrong-gh.log" GH_ARTIFACT_METADATA="$tmp/wrong-artifact.json" \
    ARTIFACT_ID=9001 EXPECTED_NAME=secretless-npm-cache-7001-3 GH_TOKEN=token RUN_ID=7001 \
    GITHUB_REPOSITORY=Verjson/example bash "$tmp/delete.sh" >/dev/null 2>&1 \
    || grep -q -- '--method DELETE' "$tmp/wrong-gh.log"; then
  fail "cleanup deleted an artifact from another run attempt"
else
  pass "cleanup fails closed before deleting an artifact from another attempt"
fi

exit "$failures"
