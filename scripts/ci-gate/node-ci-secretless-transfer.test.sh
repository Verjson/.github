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
  && pass "secretless transfer uses an exact-attempt cache without artifact permissions" \
  || fail "secretless transfer workflow structure violates its storage or trust contract"
import sys
import yaml

doc = yaml.safe_load(open(sys.argv[1], encoding="utf-8"))
jobs = doc["jobs"]
acquire = jobs["acquire-secretless-dependencies"]
build = jobs["build-test"]

assert acquire["outputs"]["transfer-cache-key"] == "${{ steps.create-secretless-cache-key.outputs.cache-key }}"
assert acquire["outputs"]["transfer-payload-bytes"] == "${{ steps.package-secretless-transfer.outputs.payload-bytes }}"
assert acquire["outputs"]["transfer-payload-sha256"] == "${{ steps.package-secretless-transfer.outputs.payload-sha256 }}"
assert "transfer-artifact-id" not in acquire["outputs"]
assert acquire["outputs"]["auxiliary-content-path"] == "${{ steps.resolve-auxiliary-source.outputs.content-path }}"
create_key = next(step for step in acquire["steps"] if step.get("id") == "create-secretless-cache-key")
assert "openssl rand -hex 32" in create_key["run"]
assert "secretless-npm-cache-${RUN_ID}-${RUN_ATTEMPT}-${nonce}" in create_key["run"]
save = next(step for step in acquire["steps"] if step.get("id") == "save-secretless-transfer")
assert save["uses"] == "actions/cache/save@55cc8345863c7cc4c66a329aec7e433d2d1c52a9"
assert save["with"]["key"] == "${{ steps.create-secretless-cache-key.outputs.cache-key }}"
assert "node_modules" not in save["with"]["path"]

package = next(step for step in acquire["steps"] if step.get("name") == "Package bounded credential-free npm cache")
assert package["id"] == "package-secretless-transfer"
assert package["env"]["MAX_PAYLOAD_BYTES"] == "83886080"
assert "_cacache/content-v2" in package["run"]
assert "npm-private-cache.tar" in package["run"]
assert "payload_bytes" in package["run"]
assert "run_attempt=$RUN_ATTEMPT" in package["run"]
assert "lock_sha256=$lock_sha256" in package["run"]
assert "auxiliary_commit=$AUXILIARY_COMMIT" in package["run"]
assert "payload-bytes=%s" in package["run"]
assert "payload-sha256=%s" in package["run"]
assert '>> "$GITHUB_OUTPUT"' in package["run"]
acquire_cleanup = next(step for step in acquire["steps"] if step.get("name") == "Remove local acquisition and transfer state")
assert acquire_cleanup["if"] == "always()"

restore = next(step for step in build["steps"] if step.get("id") == "restore-secretless-transfer")
assert restore["uses"] == "actions/cache/restore@55cc8345863c7cc4c66a329aec7e433d2d1c52a9"
assert restore["with"]["key"] == "${{ needs.acquire-secretless-dependencies.outputs.transfer-cache-key }}"
assert restore["with"]["fail-on-cache-miss"] is True
assert "restore-keys" not in restore["with"]
install = next(step for step in build["steps"] if step.get("name") == "Install from verified secretless npm cache")
setup_index = next(index for index, step in enumerate(build["steps"]) if str(step.get("uses", "")).startswith("actions/setup-node@"))
setup = build["steps"][setup_index]
install_index = build["steps"].index(install)
assert setup_index < install_index
assert "!(inputs.secretless-pr || inputs.secretless-trusted-ref)" in setup["with"]["cache"]
for credential in (
    "GH_TOKEN", "GITHUB_TOKEN", "NODE_AUTH_TOKEN", "NPM_TOKEN",
    "AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY", "AWS_SESSION_TOKEN",
    "GOOGLE_APPLICATION_CREDENTIALS", "AZURE_CREDENTIALS",
    "ACTIONS_ID_TOKEN_REQUEST_TOKEN", "ACTIONS_ID_TOKEN_REQUEST_URL",
):
    assert install["env"][credential] == ""
assert install["env"]["MAX_PAYLOAD_BYTES"] == package["env"]["MAX_PAYLOAD_BYTES"]
assert install["env"]["EXPECTED_PAYLOAD_BYTES"] == "${{ needs.acquire-secretless-dependencies.outputs.transfer-payload-bytes }}"
assert install["env"]["EXPECTED_PAYLOAD_SHA256"] == "${{ needs.acquire-secretless-dependencies.outputs.transfer-payload-sha256 }}"
assert install["env"]["NPM_CONFIG_CACHE"].startswith("${{ runner.temp }}/secretless-runtime-cache-")
assert install["env"]["NPM_CONFIG_GLOBALCONFIG"].startswith("${{ runner.temp }}/")
assert install["env"]["NPM_CONFIG_USERCONFIG"].startswith("${{ runner.temp }}/")
assert "npm ci --ignore-scripts --prefer-offline --no-audit --no-fund" in install["run"]
assert "manifest_run_attempt" in install["run"]
assert "manifest_lock_sha256" in install["run"]
assert "manifest_payload_sha256" in install["run"]
assert '"$manifest_payload_sha256" = "$EXPECTED_PAYLOAD_SHA256"' in install["run"]
assert '"$manifest_payload_bytes" = "$EXPECTED_PAYLOAD_BYTES"' in install["run"]
assert 'tarfile.open(sys.argv[1], "r:")' in install["run"]
assert '-xf "$payload"' in install["run"]
assert "locked private package content is missing or corrupt" in install["run"]
build_cleanup = next(step for step in build["steps"] if step.get("name") == "Remove local secretless transfer state")
assert "always()" in build_cleanup["if"]
assert "needs.eligibility.outputs.should-run != 'false'" in build_cleanup["if"]
runtime_cleanup = next(step for step in build["steps"] if step.get("name") == "Remove job-scoped secretless runtime cache")
assert "always()" in runtime_cleanup["if"]
assert "inputs.secretless-pr" in runtime_cleanup["if"]

assert "cleanup-secretless-transfer" not in jobs
assert "actions/upload-artifact@" not in str(acquire)
assert "actions/download-artifact@" not in str(build)
assert "actions: write" not in open(sys.argv[1], encoding="utf-8").read()

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
    "Populate verified private dependency cache": "populate.sh",
    "Package bounded credential-free npm cache": "package.sh",
    "Install from verified secretless npm cache": "install.sh",
}
for job in doc["jobs"].values():
    for step in job.get("steps", []):
        name = step.get("name")
        if name in names:
            with open(f"{root}/{names[name]}", "w", encoding="utf-8") as stream:
                stream.write(step["run"])
populate = next(step for step in doc["jobs"]["acquire-secretless-dependencies"]["steps"]
                if step.get("name") == "Populate verified private dependency cache")
assert '${#expected_content[@]}' in populate["run"]
PY

mkdir -p "$tmp/bin" "$tmp/acquire/cache/_cacache/content-v2/sha512" "$tmp/acquire/node_modules"
printf 'cached private package bytes\n' > "$tmp/private-package.tgz"
private_digest="$(sha512sum "$tmp/private-package.tgz" | cut -d' ' -f1)"
private_integrity="sha512-$(openssl dgst -sha512 -binary "$tmp/private-package.tgz" | base64 -w0)"
private_content="$tmp/acquire/cache/_cacache/content-v2/sha512/${private_digest:0:2}/${private_digest:2:2}/${private_digest:4}"
mkdir -p "$(dirname "$private_content")"
cp "$tmp/private-package.tgz" "$private_content"
printf '%s\n' "{\"name\":\"fixture\",\"version\":\"1.0.0\",\"lockfileVersion\":3,\"packages\":{\"\":{\"name\":\"fixture\",\"version\":\"1.0.0\"},\"node_modules/@verjson/private-fixture\":{\"name\":\"@verjson/private-fixture\",\"version\":\"1.0.0\",\"resolved\":\"https://npm.pkg.github.com/download/@verjson/private-fixture/1.0.0/abc\",\"integrity\":\"$private_integrity\"}}}" \
  > "$tmp/acquire/package-lock.json"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'printf '\''%s\n'\'' "$*" >> "$NPM_STUB_LOG"' \
  'if [ "${1:-} ${2:-}" = "cache add" ]; then' \
  '  while [ "$#" -gt 0 ]; do' \
  '    if [ "$1" = --cache ]; then cache_dir="$2"; break; fi' \
  '    shift' \
  '  done' \
  '  content_path="$cache_dir/_cacache/content-v2/sha512/${NPM_STUB_DIGEST:0:2}/${NPM_STUB_DIGEST:2:2}/${NPM_STUB_DIGEST:4}"' \
  '  mkdir -p "$(dirname "$content_path")"' \
  '  cp "$NPM_STUB_CONTENT" "$content_path"' \
  'fi' \
  > "$tmp/bin/npm"
chmod +x "$tmp/bin/npm"

mkdir -p "$tmp/empty"
: > "$tmp/empty/private-entries"
if PRIVATE_CACHE_ENTRIES="$tmp/empty/private-entries" \
    APPROVED_INTERNAL_SCOPES=@verjson NODE_AUTH_TOKEN=token \
    NPM_CONFIG_CACHE="$tmp/empty/cache" \
    NPM_CONFIG_GLOBALCONFIG="$tmp/empty/empty-global.npmrc" \
    NPM_CONFIG_USERCONFIG="$tmp/empty/acquisition.npmrc" \
    NPM_STUB_LOG="$tmp/empty/npm.log" PATH="$tmp/bin:$PATH" \
    bash "$tmp/populate.sh" \
    && [ -d "$tmp/empty/cache/_cacache/content-v2" ] \
    && [ ! -e "$tmp/empty/npm.log" ]; then
  pass "an empty approved package set produces a valid empty private cache without tokened npm requests"
else
  fail "an empty approved package set did not produce a bounded credential-free handoff"
fi

mkdir -p "$tmp/duplicate-digest"
printf '%s\t%s\n%s\t%s\n' \
  'https://npm.pkg.github.com/download/@verjson/one/1.0.0/abc' "$private_digest" \
  'https://npm.pkg.github.com/download/@verjson/two/1.0.0/def' "$private_digest" \
  > "$tmp/duplicate-digest/private-entries"
if PRIVATE_CACHE_ENTRIES="$tmp/duplicate-digest/private-entries" \
    APPROVED_INTERNAL_SCOPES=@verjson NODE_AUTH_TOKEN=token \
    NPM_CONFIG_CACHE="$tmp/duplicate-digest/cache" \
    NPM_CONFIG_GLOBALCONFIG="$tmp/duplicate-digest/empty-global.npmrc" \
    NPM_CONFIG_USERCONFIG="$tmp/duplicate-digest/acquisition.npmrc" \
    NPM_STUB_CONTENT="$tmp/private-package.tgz" NPM_STUB_DIGEST="$private_digest" \
    NPM_STUB_LOG="$tmp/duplicate-digest/npm.log" PATH="$tmp/bin:$PATH" \
    bash "$tmp/populate.sh"; then
  pass "private URLs sharing one digest count one content-addressed blob"
else
  fail "duplicate private digests were counted as distinct cache content"
fi

if (cd "$tmp/acquire" && PATH="$tmp/bin:$PATH" NPM_STUB_LOG="$tmp/npm.log" \
    CACHE_DIR="$tmp/acquire/cache" TRANSFER_DIR="$tmp/acquire/transfer" \
    AUXILIARY_COMMIT='' AUXILIARY_CONTENT_PATH='' AUXILIARY_REPOSITORY='' \
    GITHUB_WORKSPACE="$tmp/acquire" \
    GITHUB_OUTPUT="$tmp/acquire/package.outputs" \
    NPM_CONFIG_GLOBALCONFIG="$tmp/acquire/empty-global.npmrc" \
    NPM_CONFIG_USERCONFIG="$tmp/acquire/empty-user.npmrc" \
    MAX_PAYLOAD_BYTES=83886080 RUN_ID=7001 RUN_ATTEMPT=3 bash "$tmp/package.sh") \
    && [ ! -d "$tmp/acquire/node_modules" ] \
    && grep -qFx 'run_id=7001' "$tmp/acquire/transfer/manifest" \
    && grep -qFx 'run_attempt=3' "$tmp/acquire/transfer/manifest" \
    && tar -tf "$tmp/acquire/transfer/npm-private-cache.tar" | grep -q '^_cacache/content-v2/' \
    && ! tar -tf "$tmp/acquire/transfer/npm-private-cache.tar" | grep -q 'index-v5'; then
  pass "packaging transfers only private content blobs and binds run, attempt, lock, digest, and size"
else
  fail "packaging did not produce the bounded identity-bound cache transfer"
fi

mkdir -p "$tmp/oversize/cache/_cacache/content-v2" "$tmp/oversize/node_modules"
for index in $(seq 1 256); do printf '%s' "$index" | sha256sum; done \
  > "$tmp/oversize/cache/_cacache/content-v2/blob"
cp "$tmp/acquire/package-lock.json" "$tmp/oversize/package-lock.json"
if (cd "$tmp/oversize" && PATH="$tmp/bin:$PATH" NPM_STUB_LOG="$tmp/npm.log" \
    CACHE_DIR="$tmp/oversize/cache" TRANSFER_DIR="$tmp/oversize/transfer" \
    AUXILIARY_COMMIT='' AUXILIARY_CONTENT_PATH='' AUXILIARY_REPOSITORY='' \
    GITHUB_WORKSPACE="$tmp/oversize" \
    GITHUB_OUTPUT="$tmp/oversize/package.outputs" \
    NPM_CONFIG_GLOBALCONFIG="$tmp/oversize/empty-global.npmrc" \
    NPM_CONFIG_USERCONFIG="$tmp/oversize/empty-user.npmrc" \
    MAX_PAYLOAD_BYTES=1024 RUN_ID=7001 RUN_ATTEMPT=3 bash "$tmp/package.sh") >/dev/null 2>&1; then
  fail "a cache over the declared transfer budget was packaged"
else
  pass "a cache over the declared transfer budget fails before save"
fi

run_install() {
  local fixture="$1" run_id="${2:-7001}" run_attempt="${3:-3}"
  local auxiliary_repository="${4:-}" auxiliary_commit="${5:-}" auxiliary_content_path="${6:-}"
  local expected_payload_sha256 expected_payload_bytes
  expected_payload_sha256="$(sed -n 's/^payload_sha256=//p' "$fixture/transfer/manifest")"
  expected_payload_bytes="$(sed -n 's/^payload_bytes=//p' "$fixture/transfer/manifest")"
  (cd "$fixture" && PATH="$tmp/bin:$PATH" NPM_STUB_LOG="$fixture/npm.log" \
    GITHUB_ENV="$fixture/github.env" NPM_CONFIG_USERCONFIG="$fixture/empty.npmrc" \
    NPM_CONFIG_CACHE="$fixture/runtime-cache" \
    NPM_CONFIG_GLOBALCONFIG="$fixture/empty-global.npmrc" \
    EXPECTED_AUXILIARY_COMMIT="$auxiliary_commit" \
    EXPECTED_AUXILIARY_CONTENT_PATH="$auxiliary_content_path" \
    EXPECTED_AUXILIARY_REPOSITORY="$auxiliary_repository" GITHUB_WORKSPACE="$fixture" \
    EXPECTED_PAYLOAD_BYTES="$expected_payload_bytes" \
    EXPECTED_PAYLOAD_SHA256="$expected_payload_sha256" \
    SECRETLESS_CACHE_DIR="$fixture/build-cache" TRANSFER_DIR="$fixture/transfer" \
    MAX_PAYLOAD_BYTES=83886080 RUN_ID="$run_id" RUN_ATTEMPT="$run_attempt" \
    bash "$tmp/install.sh")
}

rebind_payload_manifest() {
  local fixture="$1"
  local payload="$fixture/transfer/npm-private-cache.tar"
  local digest bytes
  digest="$(sha256sum "$payload" | cut -d' ' -f1)"
  bytes="$(stat -c %s "$payload")"
  sed -i "s/^payload_sha256=.*/payload_sha256=$digest/; s/^payload_bytes=.*/payload_bytes=$bytes/" \
    "$fixture/transfer/manifest"
}

mkdir -p "$tmp/build"
cp "$tmp/acquire/package-lock.json" "$tmp/build/package-lock.json"
cp -R "$tmp/acquire/transfer" "$tmp/build/transfer"
if run_install "$tmp/build" \
    && grep -qF 'ci --ignore-scripts --prefer-offline --no-audit --no-fund --cache ' "$tmp/build/npm.log" \
    && [ ! -e "$tmp/build/transfer" ] && [ ! -e "$tmp/build/build-cache" ] \
    && grep -qFx 'NODE_AUTH_TOKEN=' "$tmp/build/github.env" \
    && grep -qFx 'npm_config_cache='"$tmp/build/runtime-cache" "$tmp/build/github.env" \
    && grep -qFx 'ACTIONS_ID_TOKEN_REQUEST_TOKEN=' "$tmp/build/github.env"; then
  pass "a matching private-only transfer installs credentiallessly and scrubs local state"
else
  fail "the credentialless install did not consume and clean a valid private-only transfer"
fi

mkdir -p "$tmp/missing-private"
cp "$tmp/acquire/package-lock.json" "$tmp/missing-private/package-lock.json"
cp -R "$tmp/acquire/transfer" "$tmp/missing-private/transfer"
missing_payload="$tmp/missing-private/transfer/npm-private-cache.tar"
python3 - "$missing_payload" <<'PY'
import sys
import tarfile
import tempfile
from pathlib import Path

payload = Path(sys.argv[1])
with tempfile.TemporaryDirectory() as directory:
    root = Path(directory)
    with tarfile.open(payload, "r:") as archive:
        archive.extractall(root, filter="data")
    for content in (root / "_cacache" / "content-v2" / "sha512").glob("*/*/*"):
        content.unlink()
        break
    with tarfile.open(payload, "w:") as archive:
        archive.add(root / "_cacache", arcname="_cacache")
PY
rebind_payload_manifest "$tmp/missing-private"
if missing_output="$(run_install "$tmp/missing-private" 2>&1)" \
    || [ -e "$tmp/missing-private/npm.log" ] \
    || ! grep -qF 'locked private package content is missing or corrupt' <<< "$missing_output"; then
  fail "missing private content was not rejected before npm"
else
  pass "missing private content fails closed before npm or lifecycle scripts"
fi

for mutation in poisoned-private extra-private; do
  mkdir -p "$tmp/$mutation"
  cp "$tmp/acquire/package-lock.json" "$tmp/$mutation/package-lock.json"
  cp -R "$tmp/acquire/transfer" "$tmp/$mutation/transfer"
  python3 - "$tmp/$mutation/transfer/npm-private-cache.tar" "$mutation" <<'PY'
import sys
import tarfile
import tempfile
from pathlib import Path

payload = Path(sys.argv[1])
mutation = sys.argv[2]
with tempfile.TemporaryDirectory() as directory:
    root = Path(directory)
    with tarfile.open(payload, "r:") as archive:
        archive.extractall(root, filter="data")
    content_root = root / "_cacache" / "content-v2" / "sha512"
    if mutation == "poisoned-private":
        next(content_root.glob("*/*/*")).write_bytes(b"poisoned\n")
    else:
        extra = content_root / "00" / "00" / ("0" * 124)
        extra.parent.mkdir(parents=True)
        extra.write_bytes(b"extra\n")
    with tarfile.open(payload, "w:") as archive:
        archive.add(root / "_cacache", arcname="_cacache")
PY
  rebind_payload_manifest "$tmp/$mutation"
done
if poisoned_output="$(run_install "$tmp/poisoned-private" 2>&1)" \
    || [ -e "$tmp/poisoned-private/npm.log" ] \
    || ! grep -qF 'locked private package content is missing or corrupt' <<< "$poisoned_output"; then
  fail "poisoned private content was not rejected before npm"
else
  pass "poisoned private content fails closed before npm or lifecycle scripts"
fi
if extra_output="$(run_install "$tmp/extra-private" 2>&1)" \
    || [ -e "$tmp/extra-private/npm.log" ] \
    || ! grep -qF 'private cache contains content outside the locked package set' <<< "$extra_output"; then
  fail "extra private cache content was not rejected before npm"
else
  pass "content outside the locked private package set fails before npm"
fi

auxiliary_commit='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
mkdir -p "$tmp/aux-acquire/cache/_cacache/content-v2/sha512/${private_digest:0:2}/${private_digest:2:2}" \
  "$tmp/aux-acquire/.worker-schema/migrations"
cp "$tmp/private-package.tgz" \
  "$tmp/aux-acquire/cache/_cacache/content-v2/sha512/${private_digest:0:2}/${private_digest:2:2}/${private_digest:4}"
printf 'create table fixture();\n' > "$tmp/aux-acquire/.worker-schema/migrations/102_storage.sql"
cp "$tmp/acquire/package-lock.json" "$tmp/aux-acquire/package-lock.json"
if (cd "$tmp/aux-acquire" && PATH="$tmp/bin:$PATH" NPM_STUB_LOG="$tmp/npm.log" \
    AUXILIARY_REPOSITORY=tequityapp/tequity-worker AUXILIARY_COMMIT="$auxiliary_commit" \
    AUXILIARY_CONTENT_PATH=.worker-schema/migrations GITHUB_WORKSPACE="$tmp/aux-acquire" \
    GITHUB_OUTPUT="$tmp/aux-acquire/package.outputs" \
    CACHE_DIR="$tmp/aux-acquire/cache" TRANSFER_DIR="$tmp/aux-acquire/transfer" \
    NPM_CONFIG_GLOBALCONFIG="$tmp/aux-acquire/empty-global.npmrc" \
    NPM_CONFIG_USERCONFIG="$tmp/aux-acquire/empty-user.npmrc" \
    MAX_PAYLOAD_BYTES=83886080 RUN_ID=7001 RUN_ATTEMPT=3 bash "$tmp/package.sh") \
    && grep -qFx 'auxiliary_repository=tequityapp/tequity-worker' "$tmp/aux-acquire/transfer/manifest" \
    && grep -qFx "auxiliary_commit=$auxiliary_commit" "$tmp/aux-acquire/transfer/manifest"; then
  pass "the immutable auxiliary sparse content shares the bounded identity-bound payload"
else
  fail "auxiliary sparse content was not bound into the transfer"
fi

mkdir -p "$tmp/aux-build"
cp "$tmp/aux-acquire/package-lock.json" "$tmp/aux-build/package-lock.json"
cp -R "$tmp/aux-acquire/transfer" "$tmp/aux-build/transfer"
if run_install "$tmp/aux-build" 7001 3 tequityapp/tequity-worker "$auxiliary_commit" .worker-schema/migrations \
    && grep -qFx 'create table fixture();' "$tmp/aux-build/.worker-schema/migrations/102_storage.sql"; then
  pass "a matching auxiliary source is restored only after full manifest verification"
else
  fail "a valid auxiliary source was not restored for credentialless execution"
fi

mkdir -p "$tmp/aux-wrong"
cp "$tmp/aux-acquire/package-lock.json" "$tmp/aux-wrong/package-lock.json"
cp -R "$tmp/aux-acquire/transfer" "$tmp/aux-wrong/transfer"
if run_install "$tmp/aux-wrong" 7001 3 attacker/other "$auxiliary_commit" .worker-schema/migrations >/dev/null 2>&1 \
    || [ -e "$tmp/aux-wrong/npm.log" ]; then
  fail "a mismatched auxiliary repository reached npm"
else
  pass "a mismatched auxiliary repository fails before npm"
fi

for mutation in attempt lock digest; do
  fixture="$tmp/reject-$mutation"
  mkdir -p "$fixture"
  cp "$tmp/acquire/package-lock.json" "$fixture/package-lock.json"
  cp -R "$tmp/acquire/transfer" "$fixture/transfer"
  case "$mutation" in
    attempt) run_id=7001; run_attempt=4 ;;
    lock) printf '\n' >> "$fixture/package-lock.json"; run_id=7001; run_attempt=3 ;;
    digest) printf 'tamper\n' >> "$fixture/transfer/npm-private-cache.tar"; run_id=7001; run_attempt=3 ;;
  esac
  if run_install "$fixture" "$run_id" "$run_attempt" >/dev/null 2>&1 || [ -e "$fixture/npm.log" ]; then
    fail "a transfer with a mismatched $mutation identity reached npm"
  else
    pass "a transfer with a mismatched $mutation identity fails before npm"
  fi
done

mkdir -p "$tmp/corrupt"
cp "$tmp/acquire/package-lock.json" "$tmp/corrupt/package-lock.json"
cp -R "$tmp/acquire/transfer" "$tmp/corrupt/transfer"
printf 'not a tar archive\n' > "$tmp/corrupt/transfer/npm-private-cache.tar"
if ! rebind_payload_manifest "$tmp/corrupt"; then
  fail "could not prepare the corrupt private payload fixture"
elif run_install "$tmp/corrupt" >/dev/null 2>&1 || [ -e "$tmp/corrupt/npm.log" ]; then
  fail "a corrupt private payload reached npm"
else
  pass "a corrupt private payload fails before npm"
fi

mkdir -p "$tmp/traversal"
cp "$tmp/acquire/package-lock.json" "$tmp/traversal/package-lock.json"
cp -R "$tmp/acquire/transfer" "$tmp/traversal/transfer"
python3 - "$tmp/traversal/transfer/npm-private-cache.tar" <<'PY'
import io
import sys
import tarfile

with tarfile.open(sys.argv[1], "w:") as archive:
    cache = tarfile.TarInfo("_cacache")
    cache.type = tarfile.DIRTYPE
    archive.addfile(cache)
    content = tarfile.TarInfo("_cacache/content-v2")
    content.type = tarfile.DIRTYPE
    archive.addfile(content)
    content = b"escape\n"
    member = tarfile.TarInfo("../escape")
    member.size = len(content)
    archive.addfile(member, io.BytesIO(content))
PY
if ! rebind_payload_manifest "$tmp/traversal"; then
  fail "could not prepare the traversal private payload fixture"
elif traversal_output="$(run_install "$tmp/traversal" 2>&1)"; then
  fail "a traversal member escaped private payload validation"
elif [ -e "$tmp/traversal/npm.log" ] || [ -e "$tmp/traversal/escape" ] \
    || ! grep -qF 'unsafe secretless transfer path: ../escape' <<< "$traversal_output"; then
  fail "a traversal member escaped private payload validation"
else
  pass "a traversal member in a private payload fails before extraction and npm"
fi

exit "$failures"
