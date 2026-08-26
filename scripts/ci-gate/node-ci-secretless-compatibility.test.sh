#!/usr/bin/env bash
set -uo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
workflow="$root/.github/workflows/node-ci.yml"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
failures=0
pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'not ok - %s\n' "$1" >&2; failures=$((failures + 1)); }

python3 - "$workflow" "$tmp" <<'PY'
import sys
from pathlib import Path
import yaml
doc = yaml.safe_load(Path(sys.argv[1]).read_text(encoding="utf-8"))
inputs = doc[True]["workflow_call"]["inputs"]
assert inputs["secretless-compatibility-ranges"]["default"] == ""
jobs = doc["jobs"]
steps = {step.get("name"): step for job in jobs.values()
         for step in job.get("steps", []) if step.get("name")}
for name, filename in {
    "Validate approved internal dependency lock": "validate.sh",
    "Resolve approved compatibility ranges without lifecycle execution": "resolve.sh",
    "Package bounded credential-free npm cache": "package.sh",
    "Install from verified secretless npm cache": "install.sh",
    "Run runtime-resolved compatibility lanes without credentials": "run-lanes.sh",
}.items():
    Path(sys.argv[2], filename).write_text(steps[name]["run"], encoding="utf-8")
assert jobs["acquire-secretless-dependencies"]["permissions"] == {"contents": "read", "packages": "read"}
assert jobs["build-test"]["permissions"] == {"contents": "read"}
runner = steps["Run runtime-resolved compatibility lanes without credentials"]
for name in ("GH_TOKEN", "GITHUB_TOKEN", "NODE_AUTH_TOKEN", "NPM_TOKEN",
             "ACTIONS_ID_TOKEN_REQUEST_TOKEN", "ACTIONS_ID_TOKEN_REQUEST_URL"):
    assert runner["env"][name] == ""
assert "tarfile.open" in runner["run"] and "O_NOFOLLOW" in runner["run"]
assert 'subprocess.run(["npm", "install"' not in runner["run"]
assert "artifact.read_bytes" not in runner["run"]
assert "os.fstat(descriptor)" in runner["run"] and "io.BytesIO(content)" in runner["run"]
assert "extractall" not in runner["run"]
PY
[ "$?" -eq 0 ] && pass "compatibility lanes retain the canonical two-job credential boundary" \
  || fail "compatibility lanes do not retain the canonical two-job credential boundary"

request='{"package":"@verjson/identity-contracts","ranges":["^0.2.0"],"script":"test:compat"}'
policy='{"scopes":["@verjson"],"packages":["@verjson/identity-contracts"],"compatibility":{"@verjson/identity-contracts":["0.2.2","^0.2.0","~0.2.0",">=0.2.2 <0.4.0"]}}'
mkdir -p "$tmp/validate"
printf '%s\n' '{"name":"consumer","version":"1.0.0","lockfileVersion":3,"packages":{"":{"name":"consumer","version":"1.0.0"}}}' > "$tmp/validate/package-lock.json"
run_validator() {
  rm -f "$tmp/validate/private-entries"
  (cd "$tmp/validate" && APPROVED_INTERNAL_PACKAGES="$1" APPROVED_INTERNAL_SCOPES=@verjson \
    COMPATIBILITY_RANGES="$2" PACKAGE_MANAGER=npm PRIVATE_CACHE_ENTRIES="$tmp/validate/private-entries" \
    TRUSTED_PACKAGE_POLICY="${3-}" bash "$tmp/validate.sh")
}
if run_validator '@verjson/identity-contracts' "$request" "$policy" >/dev/null 2>&1; then
  pass "an exact approved compatibility package may be absent from the pinned lock"
else
  fail "an exact approved compatibility package was rejected"
fi
unapproved='{"package":"@verjson/other","ranges":["^0.2.0"],"script":"test:compat"}'
if run_validator '@verjson/identity-contracts' "$unapproved" "$policy" >/dev/null 2>&1; then
  fail "an unapproved compatibility package was accepted"
else
  pass "an unapproved compatibility package fails before registry access"
fi
caller_bypass='{"package":"@verjson/private-target","ranges":["^1.0.0"],"script":"test:compat"}'
if run_validator '@verjson/private-target' "$caller_bypass" '' >/dev/null 2>&1; then
  fail "caller-controlled package and absent-lock exemption bypassed protected policy"
else
  pass "combined caller-controlled package and absent-lock exemption fails without protected policy"
fi
package_only_policy='{"scopes":["@verjson"],"packages":["@verjson/identity-contracts"]}'
if run_validator '@verjson/identity-contracts' "$request" "$package_only_policy" >/dev/null 2>&1; then
  fail "package-only protected policy authorized caller-controlled compatibility ranges"
else
  pass "compatibility ranges require explicit protected-policy authorization"
fi
range_expansion='{"package":"@verjson/identity-contracts","ranges":["^1.0.0"],"script":"test:compat"}'
if run_validator '@verjson/identity-contracts' "$range_expansion" "$policy" >/dev/null 2>&1; then
  fail "caller-controlled range expanded beyond protected policy"
else
  pass "caller-controlled range cannot expand protected policy"
fi
for range_value in 'file:../payload' '>=0' '>=0.0.0' '*' '1.2' '>=2.0.0 <1.0.0' '>=1.0.0'; do
  bad_range="{\"package\":\"@verjson/identity-contracts\",\"ranges\":[\"$range_value\"],\"script\":\"test:compat\"}"
  bad_policy="{\"scopes\":[\"@verjson\"],\"packages\":[\"@verjson/identity-contracts\"],\"compatibility\":{\"@verjson/identity-contracts\":[\"$range_value\"]}}"
  if run_validator '@verjson/identity-contracts' "$bad_range" "$bad_policy" >/dev/null 2>&1; then
    fail "unbounded or unsupported compatibility range $range_value was accepted"
  else
    pass "unbounded or unsupported compatibility range $range_value fails before registry access"
  fi
done
for range_value in '0.2.2' '^0.2.0' '~0.2.0' '>=0.2.2 <0.4.0'; do
  bounded="{\"package\":\"@verjson/identity-contracts\",\"ranges\":[\"$range_value\"],\"script\":\"test:compat\"}"
  if run_validator '@verjson/identity-contracts' "$bounded" "$policy" >/dev/null 2>&1; then
    pass "bounded compatibility range $range_value is accepted"
  else
    fail "bounded compatibility range $range_value was rejected"
  fi
done

mkdir -p "$tmp/resolve/bin" "$tmp/resolve/runner"
printf 'compatibility fixture\n' > "$tmp/resolve/package.tgz"
fixture_integrity="sha512-$(openssl dgst -sha512 -binary "$tmp/resolve/package.tgz" | openssl base64 -A)"
cat > "$tmp/resolve/bin/npm" <<'SH'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$*" >> "$NPM_STUB_LOG"
spec="${3:-}"
for category in auth-fail access-fail missing empty; do
  if [[ "$spec" == *"$category"* ]]; then
    case "$category" in auth-fail) code=E401;; access-fail) code=E403;; missing) code=E404;; empty) code=ETARGET;; esac
    echo "npm ERR! code $code token=$NODE_AUTH_TOKEN" >&2
    exit 1
  fi
done
if [ "${4:-}" = version ] && [ "$#" -eq 4 ]; then
  printf '%s\n' '["0.2.1","0.2.2"]'
else
  printf '%s\n' "{\"name\":\"@verjson/identity-contracts\",\"version\":\"0.2.2\",\"dist.integrity\":\"$NPM_STUB_INTEGRITY\",\"dist.tarball\":\"https://npm.pkg.github.com/download/@verjson/identity-contracts/0.2.2/archive\"}"
fi
SH
chmod +x "$tmp/resolve/bin/npm"
run_resolver() {
  rm -rf "$tmp/resolve/runner/_compatibility"
  : > "$tmp/resolve/private-entries"
  (cd "$tmp/resolve" && PATH="$tmp/resolve/bin:$PATH" NPM_STUB_LOG="$tmp/resolve/npm.log" \
    NPM_STUB_INTEGRITY="$fixture_integrity" NODE_AUTH_TOKEN=runtime-package-token \
    APPROVED_INTERNAL_SCOPES=@verjson COMPATIBILITY_RANGES="$1" \
    COMPATIBILITY_PROVENANCE="$tmp/resolve/runner/_compatibility/provenance.json" \
    PRIVATE_CACHE_ENTRIES="$tmp/resolve/private-entries" NPM_CONFIG_GLOBALCONFIG="$tmp/resolve/runner/global.npmrc" \
    NPM_CONFIG_USERCONFIG="$tmp/resolve/runner/user.npmrc" bash "$tmp/resolve.sh") >"$2" 2>&1
}
if run_resolver "$request" "$tmp/resolve/success.log" && \
  python3 - "$tmp/resolve/runner/_compatibility/provenance.json" <<'PY'
import json,sys
p=json.load(open(sys.argv[1],encoding="utf-8"));assert p["lanes"][0]["version"]=="0.2.2"
PY
then pass "trusted acquisition records runtime-resolved version, integrity, and provenance"; else fail "trusted acquisition did not record runtime-resolved provenance"; fi
outside_range='{"package":"@verjson/identity-contracts","ranges":["^9.0.0"],"script":"test:compat"}'
if run_resolver "$outside_range" "$tmp/resolve/outside-range.log"; then
  fail "registry-selected version outside the declared bounded range was accepted"
else
  pass "registry-selected version is rechecked against the declared bounded range"
fi
grep -Eq 'install|pack|run|exec' "$tmp/resolve/npm.log" \
  && fail "compatibility resolution invoked a lifecycle-capable npm command" \
  || pass "compatibility resolution uses metadata reads only"
for case_name in auth-fail access-fail missing empty; do
  bad="{\"package\":\"@verjson/identity-contracts\",\"ranges\":[\"${case_name}1.0.0\"],\"script\":\"test:compat\"}"
  if run_resolver "$bad" "$tmp/resolve/$case_name.log"; then
    fail "$case_name registry failure was accepted"
  elif grep -qF runtime-package-token "$tmp/resolve/$case_name.log"; then
    fail "$case_name registry diagnostic leaked the package token"
  else
    case "$case_name" in auth-fail) expected='authentication failed';; access-fail) expected='package access denied';; missing) expected='package is absent or unreadable';; empty) expected='compatibility range has no readable version';; esac
    grep -qF "$expected" "$tmp/resolve/$case_name.log" && pass "$case_name registry failure is classified and scrubbed" || fail "$case_name registry failure was not classified"
  fi
done

mkdir -p "$tmp/e2e/acquire/cache/_cacache/content-v2/sha512" "$tmp/e2e/acquire/compat/_compatibility" "$tmp/e2e/acquire/work"
printf '%s\n' '{"name":"@verjson/identity-contracts","version":"0.2.2"}' > "$tmp/e2e/acquire/work/package.json"
tar -C "$tmp/e2e/acquire/work" --transform='s#^#package/#' -czf "$tmp/e2e/acquire/lane.tgz" package.json
lane_digest="$(sha512sum "$tmp/e2e/acquire/lane.tgz" | cut -d' ' -f1)"
lane_integrity="sha512-$(openssl dgst -sha512 -binary "$tmp/e2e/acquire/lane.tgz" | openssl base64 -A)"
lane_content="$tmp/e2e/acquire/cache/_cacache/content-v2/sha512/${lane_digest:0:2}/${lane_digest:2:2}/${lane_digest:4}"
mkdir -p "$(dirname "$lane_content")" && cp "$tmp/e2e/acquire/lane.tgz" "$lane_content"
printf '%s\n' '{"name":"consumer","version":"1.0.0","lockfileVersion":3,"packages":{"":{"name":"consumer","version":"1.0.0"}}}' > "$tmp/e2e/acquire/package-lock.json"
python3 - "$tmp/e2e/acquire/compat/_compatibility/provenance.json" "$lane_integrity" "$lane_digest" <<'PY'
import json,sys
r={"package":"@verjson/identity-contracts","ranges":["^0.2.0"],"script":"test:compat"}
l={"index":0,"package":r["package"],"range":"^0.2.0","script":"test:compat","version":"0.2.2","integrity":sys.argv[2],"tarball":"https://npm.pkg.github.com/download/@verjson/identity-contracts/0.2.2/archive","sha512":sys.argv[3]}
open(sys.argv[1],"w",encoding="utf-8").write(json.dumps({"schemaVersion":1,"request":r,"lanes":[l]},sort_keys=True,separators=(",",":"))+"\n")
PY
(cd "$tmp/e2e/acquire" && AUXILIARY_COMMIT='' AUXILIARY_CONTENT_PATH='' AUXILIARY_REPOSITORY='' \
  CACHE_DIR="$tmp/e2e/acquire/cache" COMPATIBILITY_ROOT="$tmp/e2e/acquire/compat" COMPATIBILITY_RANGES="$request" \
  GITHUB_OUTPUT="$tmp/e2e/acquire/package.output" GITHUB_WORKSPACE="$tmp/e2e/acquire" MAX_PAYLOAD_BYTES=83886080 \
  PACKAGE_MANAGER=npm RUN_ATTEMPT=1 RUN_ID=1103 TRANSFER_DIR="$tmp/e2e/acquire/transfer" bash "$tmp/package.sh")
[ "$?" -eq 0 ] && grep -q '^compatibility_provenance_sha256=' "$tmp/e2e/acquire/transfer/manifest" \
  && pass "compatibility provenance shares the bounded transfer" || fail "compatibility provenance was not packaged through the canonical transfer"

mkdir -p "$tmp/e2e/build/bin"
cp "$tmp/e2e/acquire/package-lock.json" "$tmp/e2e/build/package-lock.json" && cp -R "$tmp/e2e/acquire/transfer" "$tmp/e2e/build/transfer"
printf '%s\n' '#!/usr/bin/env bash' 'printf "%s\n" "$*" >> "$NPM_STUB_LOG"' '[ "${1:-}" = ci ]' > "$tmp/e2e/build/bin/npm"
chmod +x "$tmp/e2e/build/bin/npm"
provenance_sha="$(sed -n 's/^compatibility_provenance_sha256=//p' "$tmp/e2e/build/transfer/manifest")"
run_install() {
  local fixture="$1"
  (cd "$fixture" && PATH="$tmp/e2e/build/bin:$PATH" NPM_STUB_LOG="$fixture/npm.log" APPROVED_INTERNAL_SCOPES=@verjson \
    COMPATIBILITY_RANGES="$request" COMPATIBILITY_ARTIFACT_DIR="$fixture/artifacts" EXPECTED_AUXILIARY_COMMIT='' \
    EXPECTED_AUXILIARY_CONTENT_PATH='' EXPECTED_AUXILIARY_REPOSITORY='' EXPECTED_COMPATIBILITY_PROVENANCE_SHA256="$provenance_sha" \
    EXPECTED_PAYLOAD_BYTES="$(sed -n 's/^payload_bytes=//p' "$fixture/transfer/manifest")" EXPECTED_PAYLOAD_SHA256="$(sed -n 's/^payload_sha256=//p' "$fixture/transfer/manifest")" \
    GITHUB_ENV="$fixture/github.env" GITHUB_WORKSPACE="$fixture" NPM_CONFIG_CACHE="$fixture/runtime-cache" NPM_CONFIG_GLOBALCONFIG="$fixture/global.npmrc" \
    NPM_CONFIG_USERCONFIG="$fixture/user.npmrc" PACKAGE_MANAGER=npm SECRETLESS_CACHE_DIR="$fixture/secretless-cache" TRANSFER_DIR="$fixture/transfer" \
    MAX_PAYLOAD_BYTES=83886080 RUN_ATTEMPT=1 RUN_ID=1103 bash "$tmp/install.sh")
}
if run_install "$tmp/e2e/build" && [ -f "$tmp/e2e/build/artifacts/lane-0.tgz" ]; then pass "credentialless restore reconstructs the exact compatibility tarball"; else fail "credentialless restore did not reconstruct the compatibility tarball"; fi

for mutation in provenance payload; do
  fixture="$tmp/e2e/tampered-$mutation"; mkdir -p "$fixture"; cp "$tmp/e2e/acquire/package-lock.json" "$fixture/package-lock.json"; cp -R "$tmp/e2e/acquire/transfer" "$fixture/transfer"
  python3 - "$fixture/transfer/npm-private-cache.tar" "$mutation" <<'PY'
import json,pathlib,tarfile,tempfile,sys
p=pathlib.Path(sys.argv[1]);m=sys.argv[2]
with tempfile.TemporaryDirectory() as d:
 r=pathlib.Path(d)
 with tarfile.open(p,"r:") as a:a.extractall(r,filter="data")
 if m=="provenance":
  q=r/"_compatibility"/"provenance.json";v=json.loads(q.read_text());v["lanes"][0]["range"]="^9.0.0";q.write_text(json.dumps(v)+"\n")
 else:next((r/"_cacache"/"content-v2"/"sha512").glob("*/*/*")).write_bytes(b"tampered")
 with tarfile.open(p,"w:") as a:a.add(r/"_cacache",arcname="_cacache");a.add(r/"_compatibility",arcname="_compatibility")
PY
  p="$fixture/transfer/npm-private-cache.tar"; bytes="$(stat -c %s "$p")"; sha="$(sha256sum "$p" | cut -d' ' -f1)"; sed -i "s/^payload_bytes=.*/payload_bytes=$bytes/;s/^payload_sha256=.*/payload_sha256=$sha/" "$fixture/transfer/manifest"
  run_install "$fixture" >/dev/null 2>&1 && fail "tampered compatibility $mutation passed verification" || pass "tampered compatibility $mutation fails before consumer code"
done

mkdir -p "$tmp/e2e/consumer/artifacts" "$tmp/e2e/consumer/node_modules/@verjson/identity-contracts"
cp "$tmp/e2e/build/artifacts/"* "$tmp/e2e/consumer/artifacts/"
printf '%s\n' '{"name":"@verjson/identity-contracts","version":"0.1.0"}' \
  > "$tmp/e2e/consumer/node_modules/@verjson/identity-contracts/package.json"
printf '%s\n' '{"name":"consumer","version":"1.0.0","scripts":{"test:compat":"node test-compat.js"}}' > "$tmp/e2e/consumer/package.json"
printf '%s\n' "const fs=require('node:fs');const v=require('./node_modules/@verjson/identity-contracts/package.json').version;fs.writeFileSync('observed-version',v);if(process.env.REJECT_COMPATIBILITY==='true')process.exit(42);" > "$tmp/e2e/consumer/test-compat.js"
if (cd "$tmp/e2e/consumer" && COMPATIBILITY_ARTIFACT_DIR="$tmp/e2e/consumer/artifacts" COMPATIBILITY_RANGES="$request" EXPECTED_COMPATIBILITY_PROVENANCE_SHA256="$provenance_sha" REJECT_COMPATIBILITY=false bash "$tmp/run-lanes.sh") >/dev/null 2>&1 && grep -qFx 0.2.2 "$tmp/e2e/consumer/observed-version"; then pass "the resolved in-range artifact reaches the declared consumer test"; else fail "the resolved artifact did not reach the declared consumer test"; fi
(cd "$tmp/e2e/consumer" && COMPATIBILITY_ARTIFACT_DIR="$tmp/e2e/consumer/artifacts" COMPATIBILITY_RANGES="$request" EXPECTED_COMPATIBILITY_PROVENANCE_SHA256="$provenance_sha" REJECT_COMPATIBILITY=true bash "$tmp/run-lanes.sh") >/dev/null 2>&1 \
  && fail "an in-range incompatible artifact did not fail consumer tests" || pass "an in-range incompatible artifact fails at the consumer test layer"
if (cd "$tmp/e2e/consumer" && COMPATIBILITY_ARTIFACT_DIR="$tmp/e2e/consumer/artifacts" COMPATIBILITY_RANGES="$request" EXPECTED_COMPATIBILITY_PROVENANCE_SHA256="$provenance_sha" NODE_AUTH_TOKEN=leaked bash "$tmp/run-lanes.sh") >"$tmp/e2e/token.log" 2>&1; then fail "a package credential reached compatibility consumer execution"; elif grep -qF 'credential reached compatibility consumer execution' "$tmp/e2e/token.log"; then pass "consumer execution fails closed on a credential leak"; else fail "token-leak mutation failed for the wrong reason"; fi

real_npm="$(command -v npm)"
mkdir -p "$tmp/archive-cases/bin"
cat > "$tmp/archive-cases/bin/npm" <<'SH'
#!/usr/bin/env bash
set -eu
if [ "${1:-}" = run ]; then
  exec "$REAL_NPM" "$@"
fi
printf 'unexpected graph resolution: %s\n' "$*" > "$NPM_GRAPH_RESOLUTION_MARKER"
exit 97
SH
chmod +x "$tmp/archive-cases/bin/npm"

prepare_archive_case() {
  local mutation="$1"
  local fixture="$tmp/archive-cases/$mutation"
  rm -rf "$fixture"
  mkdir -p "$fixture/artifacts" \
    "$fixture/node_modules/@verjson/identity-contracts" \
    "$fixture/node_modules/cold-cache-public" \
    "$fixture/cold-cache/_cacache/content-v2/sha512"
  printf '%s\n' '{"name":"@verjson/identity-contracts","version":"0.1.0"}' \
    > "$fixture/node_modules/@verjson/identity-contracts/package.json"
  printf '%s\n' old > "$fixture/node_modules/@verjson/identity-contracts/old-sentinel"
  printf '%s\n' '{"name":"cold-cache-public","version":"1.4.0","main":"index.js"}' \
    > "$fixture/node_modules/cold-cache-public/package.json"
  printf '%s\n' 'module.exports = "cold-cache-public-1.4.0";' \
    > "$fixture/node_modules/cold-cache-public/index.js"
  printf '%s\n' \
    '{"name":"consumer","version":"1.0.0","dependencies":{"cold-cache-public":"^1.0.0"},"scripts":{"test:compat":"node test-compat.cjs"}}' \
    > "$fixture/package.json"
  cat > "$fixture/test-compat.cjs" <<'JS'
const assert = require('node:assert/strict');
const fs = require('node:fs');

assert.equal(require('./node_modules/@verjson/identity-contracts/package.json').version, '0.2.2');
assert.equal(require('cold-cache-public'), 'cold-cache-public-1.4.0');
fs.writeFileSync('consumer-ran', 'yes');
JS
  python3 - "$fixture" "$mutation" "$request" <<'PY'
import base64
import gzip
import hashlib
import io
import json
import pathlib
import sys
import tarfile

fixture = pathlib.Path(sys.argv[1])
mutation = sys.argv[2]
request = json.loads(sys.argv[3])
artifact = fixture / "artifacts" / "lane-0.tgz"
manifest = {
    "name": "@verjson/identity-contracts",
    "version": "0.2.2",
    "scripts": {"postinstall": "node -e process.exit(99)"},
}
if mutation == "wrong-name":
    manifest["name"] = "@verjson/other"
if mutation == "wrong-version":
    manifest["version"] = "9.9.9"

def add_bytes(archive, name, content, mode=0o644):
    info = tarfile.TarInfo(name)
    info.mode = mode
    info.size = len(content)
    archive.addfile(info, io.BytesIO(content))

if mutation == "oversize":
    with gzip.open(artifact, "wb") as stream:
        info = tarfile.TarInfo("package/oversize.bin")
        info.size = 64 * 1024 * 1024 + 1
        stream.write(info.tobuf())
        stream.write(b"\0" * 1024)
else:
    with tarfile.open(artifact, "w:gz") as archive:
        add_bytes(archive, "package/package.json", json.dumps(manifest).encode())
        add_bytes(archive, "package/index.js", b"export const compatible = true;\n")
        if mutation == "traversal":
            add_bytes(archive, "package/../../escape", b"escaped")
        elif mutation == "absolute":
            add_bytes(archive, "/package/escape", b"escaped")
        elif mutation == "multi-root":
            add_bytes(archive, "other/escape", b"escaped")
        elif mutation in {"symlink", "hardlink", "special", "pax"}:
            info = tarfile.TarInfo("package/unsafe")
            if mutation == "symlink":
                info.type = tarfile.SYMTYPE
                info.linkname = "../../escape"
            elif mutation == "hardlink":
                info.type = tarfile.LNKTYPE
                info.linkname = "package/package.json"
            elif mutation == "special":
                info.type = tarfile.CHRTYPE
                info.devmajor = 1
                info.devminor = 3
            else:
                info.type = tarfile.XHDTYPE
                content = b"path=package/unsafe\n"
                info.size = len(content)
                archive.addfile(info, io.BytesIO(content))
                info = None
            if info is not None:
                archive.addfile(info)
        elif mutation == "count":
            for index in range(4096):
                info = tarfile.TarInfo(f"package/members/{index}")
                info.type = tarfile.DIRTYPE
                archive.addfile(info)
        elif mutation == "duplicate":
            add_bytes(archive, "package/package.json", json.dumps(manifest).encode())

artifact_bytes = artifact.read_bytes()
digest = hashlib.sha512(artifact_bytes).digest()
lane = {
    "index": 0,
    "package": request["package"],
    "range": request["ranges"][0],
    "script": request["script"],
    "version": "0.2.2",
    "integrity": "sha512-" + base64.b64encode(digest).decode(),
    "tarball": "https://npm.pkg.github.com/download/@verjson/identity-contracts/0.2.2/archive",
    "sha512": digest.hex(),
}
provenance = json.dumps(
    {"schemaVersion": 1, "request": request, "lanes": [lane]},
    sort_keys=True,
    separators=(",", ":"),
) + "\n"
(fixture / "artifacts" / "provenance.json").write_text(provenance)
(fixture / "provenance.sha256").write_text(hashlib.sha256(provenance.encode()).hexdigest())

public_tarball = io.BytesIO()
with tarfile.open(fileobj=public_tarball, mode="w:gz") as archive:
    add_bytes(archive, "package/package.json", b'{"name":"cold-cache-public","version":"1.4.0"}')
public_bytes = public_tarball.getvalue()
public_digest = hashlib.sha512(public_bytes).digest()
public_hex = public_digest.hex()
cache_entry = fixture / "cold-cache" / "_cacache" / "content-v2" / "sha512" / public_hex[:2] / public_hex[2:4] / public_hex[4:]
cache_entry.parent.mkdir(parents=True)
cache_entry.write_bytes(public_bytes)
lock = {
    "name": "consumer",
    "version": "1.0.0",
    "lockfileVersion": 3,
    "packages": {
        "": {"name": "consumer", "version": "1.0.0", "dependencies": {"cold-cache-public": "^1.0.0"}},
        "node_modules/cold-cache-public": {
            "version": "1.4.0",
            "resolved": "https://registry.npmjs.org/cold-cache-public/-/cold-cache-public-1.4.0.tgz",
            "integrity": "sha512-" + base64.b64encode(public_digest).decode(),
        },
    },
}
(fixture / "package-lock.json").write_text(json.dumps(lock) + "\n")
PY
}

run_archive_case() {
  local mutation="$1"
  local fixture="$tmp/archive-cases/$mutation"
  prepare_archive_case "$mutation"
  (
    cd "$fixture"
    PATH="$tmp/archive-cases/bin:$PATH" \
    REAL_NPM="$real_npm" \
    NPM_GRAPH_RESOLUTION_MARKER="$fixture/npm-graph-resolution" \
    npm_config_cache="$fixture/cold-cache" \
    npm_config_offline=true \
    COMPATIBILITY_ARTIFACT_DIR="$fixture/artifacts" \
    COMPATIBILITY_RANGES="$request" \
    EXPECTED_COMPATIBILITY_PROVENANCE_SHA256="$(<"$fixture/provenance.sha256")" \
    bash "$tmp/run-lanes.sh"
  ) >"$fixture/run.log" 2>&1
}

if run_archive_case good \
    && [ -f "$tmp/archive-cases/good/consumer-ran" ] \
    && [ ! -e "$tmp/archive-cases/good/npm-graph-resolution" ] \
    && [ ! -e "$tmp/archive-cases/good/node_modules/@verjson/identity-contracts/old-sentinel" ] \
    && [ "$(find "$tmp/archive-cases/good/node_modules/@verjson" -maxdepth 1 -name '.identity-contracts.*' -print -quit)" = '' ]; then
  pass "cold-cache caret consumer swaps one verified package without resolving its graph"
else
  fail "cold-cache caret consumer did not preserve its installed dependency graph"
fi

for mutation in traversal absolute multi-root symlink hardlink special pax oversize count duplicate wrong-name wrong-version; do
  if run_archive_case "$mutation"; then
    fail "$mutation compatibility archive reached consumer execution"
  elif [ -e "$tmp/archive-cases/$mutation/consumer-ran" ] \
      || [ -e "$tmp/archive-cases/$mutation/npm-graph-resolution" ] \
      || [ -e "$tmp/archive-cases/$mutation/escape" ]; then
    fail "$mutation compatibility archive caused work before rejection"
  elif [ "$(node -p "require('$tmp/archive-cases/$mutation/node_modules/@verjson/identity-contracts/package.json').version")" != 0.1.0 ] \
    || [ ! -f "$tmp/archive-cases/$mutation/node_modules/@verjson/identity-contracts/old-sentinel" ]; then
    fail "$mutation compatibility archive disturbed the pre-existing package target"
  elif [ -n "$(find "$tmp/archive-cases/$mutation/node_modules/@verjson" -maxdepth 1 -name '.identity-contracts.*' -print -quit)" ]; then
    fail "$mutation compatibility archive left a staging or backup directory"
  else
    pass "$mutation compatibility archive fails before target swap or consumer code"
  fi
done

exit "$failures"
