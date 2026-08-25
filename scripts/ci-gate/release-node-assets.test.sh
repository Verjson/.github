#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
workflow="$root/.github/workflows/node-release.yml"
work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT
awk '/BOUNDED_RELEASE_ASSETS_BEGIN/ { active = 1 } active { sub(/^          /, ""); print } /BOUNDED_RELEASE_ASSETS_END/ { exit }' "$workflow" >"$work/assets.sh"
awk '/RESTART_SAFE_GH_RELEASE_BEGIN/ { active = 1 } active { sub(/^          /, ""); print } /RESTART_SAFE_GH_RELEASE_END/ { exit }' "$workflow" >"$work/publish.sh"
bash -n "$work/assets.sh"
bash -n "$work/publish.sh"

mkdir -p "$work/repo/contract" "$work/repo/CHANGELOG" "$work/runner" "$work/state" "$work/bin"
printf '%s\n' 'tagged schema' >"$work/repo/contract/schema.graphql"
printf '%s\n' 'tagged digest' >"$work/repo/contract/schema.sha256"
printf '%s\n' notes >"$work/repo/CHANGELOG/v1.2.3.md"
git -C "$work/repo" init -q
git -C "$work/repo" config user.name test
git -C "$work/repo" config user.email test@example.invalid
git -C "$work/repo" add contract CHANGELOG
git -C "$work/repo" commit -qm fixture

run_assets() {
  : >"$work/output"
  (cd "$work/repo" && RELEASE_ASSETS="$1" ASSET_STATE_ROOT="$work/runner/validation" \
    GITHUB_OUTPUT="$work/output" bash -euo pipefail "$work/assets.sh")
}
manifest() { sed -n 's/^manifest=//p' "$work/output"; }
rejects() {
  local name="$1" value="$2"
  if run_assets "$value" >"$work/reject.out" 2>&1; then
    echo "FAIL - accepted $name" >&2
    exit 1
  fi
  echo "ok - rejects $name"
}

run_assets '[]'
[ "$(manifest)" = '[]' ]
echo "ok - empty opt-in records an empty immutable manifest"
run_assets '["contract/schema.graphql","contract/schema.sha256"]'
release_manifest="$(manifest)"
schema_digest="$(git -C "$work/repo" show HEAD:contract/schema.graphql | sha256sum | awk '{print $1}')"
sidecar_digest="$(git -C "$work/repo" show HEAD:contract/schema.sha256 | sha256sum | awk '{print $1}')"

cat >"$work/bin/gh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
if [ "$1" = api ]; then
  case "${REMOTE_MODE:-absent}" in
    absent|race) printf '%s\n' '{"assets":[]}' ;;
    matching) printf '{"assets":[{"name":"schema.graphql","digest":"sha256:%s"},{"name":"schema.sha256","digest":"sha256:%s"}]}\n' "$SCHEMA_DIGEST" "$SIDECAR_DIGEST" ;;
    mismatch) printf '%s\n' '{"assets":[{"name":"schema.graphql","digest":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}]}' ;;
    unverifiable) printf '%s\n' '{"assets":[{"name":"schema.graphql","digest":null}]}' ;;
  esac
  exit 0
fi
[ "$1" = release ]
case "$2" in
  view) [ -e "$TEST_STATE/release" ] || exit 1; printf '%s\n' v1.2.3 ;;
  create) touch "$TEST_STATE/release" ;;
  edit) : ;;
  upload)
    [ "$#" -eq 4 ]
    [ "$4" != --clobber ]
    [ "${REMOTE_MODE:-absent}" != race ] || exit 1
    printf '%s\t' "${4##*/}" >>"$TEST_STATE/uploads"
    sha256sum "$4" | awk '{print $1}' >>"$TEST_STATE/uploads"
    ;;
  *) exit 90 ;;
esac
STUB
chmod +x "$work/bin/gh"

run_publish() {
  (cd "$work/repo" && PATH="$work/bin:/usr/local/bin:/usr/bin:/bin" TEST_STATE="$work/state" \
    ASSET_ROOT="$work/runner/assets" RELEASE_ASSET_MANIFEST="$release_manifest" \
    VERSION=v1.2.3 GH_TOKEN=test GITHUB_SERVER_URL=https://github.com \
    GITHUB_REPOSITORY=Verjson/example SCHEMA_DIGEST="$schema_digest" SIDECAR_DIGEST="$sidecar_digest" \
    REMOTE_MODE="${REMOTE_MODE:-absent}" bash -euo pipefail "$work/publish.sh")
}

printf '%s\n' hostile >"$work/repo/contract/schema.graphql"
mkdir -p "$work/runner/assets"
printf '%s\n' injected >"$work/runner/assets/injected.txt"
: >"$work/state/uploads"
run_publish
grep -qxF $'schema.graphql\t'"$schema_digest" "$work/state/uploads"
grep -qxF $'schema.sha256\t'"$sidecar_digest" "$work/state/uploads"
[ "$(wc -l <"$work/state/uploads")" -eq 2 ]
echo "ok - post-validation mutation cannot change or expand the exact tagged upload manifest"

: >"$work/state/uploads"
REMOTE_MODE=matching run_publish
[ ! -s "$work/state/uploads" ]
echo "ok - matching digest receipts make retry a no-op"
for remote_mode in mismatch unverifiable; do
  : >"$work/state/uploads"
  if REMOTE_MODE="$remote_mode" run_publish >"$work/$remote_mode.out" 2>&1; then
    echo "FAIL - accepted $remote_mode existing asset state" >&2
    exit 1
  fi
  [ ! -s "$work/state/uploads" ]
  echo "ok - $remote_mode existing asset fails closed without replacement"
done
: >"$work/state/uploads"
if REMOTE_MODE=race run_publish >"$work/race.out" 2>&1; then
  echo "FAIL - inspection/upload collision race unexpectedly succeeded" >&2
  exit 1
fi
[ ! -s "$work/state/uploads" ]
echo "ok - an asset created after inspection fails instead of being clobbered"

git -C "$work/repo" restore contract/schema.graphql
rejects 'malformed JSON' '["contract/schema.graphql"'
rejects 'a traversal path' '["../schema.graphql"]'
rejects 'an absolute path' '["/tmp/schema.graphql"]'
rejects 'a dot segment' '["contract/./schema.graphql"]'
rejects 'a duplicate path' '["contract/schema.graphql","contract/schema.graphql"]'
mkdir -p "$work/repo/other"
printf '%s\n' collision >"$work/repo/other/schema.graphql"
git -C "$work/repo" add other/schema.graphql
git -C "$work/repo" commit -qm collision
rejects 'duplicate destination basenames' '["contract/schema.graphql","other/schema.graphql"]'
rejects 'a directory' '["contract"]'
printf '%s\n' untracked >"$work/repo/untracked.txt"
rejects 'an untracked file' '["untracked.txt"]'
ln -s contract/schema.graphql "$work/repo/link.graphql"
rejects 'a symlink file' '["link.graphql"]'
ln -s contract "$work/repo/linked-contract"
rejects 'a symlink parent component' '["linked-contract/schema.graphql"]'
many='['
for index in $(seq 1 17); do many="${many}${index:+,}\"asset-$index.txt\""; done
many="${many/[,/[}]"
rejects 'more than 16 assets' "$many]"

real_git="$(command -v git)"
cat >"$work/bin/git" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
if [ "$1" = cat-file ] && [ "$2" = -s ]; then printf '%s\n' "$FAKE_BLOB_SIZE"; else exec "$REAL_GIT" "$@"; fi
STUB
chmod +x "$work/bin/git"
if (cd "$work/repo" && PATH="$work/bin:$PATH" REAL_GIT="$real_git" FAKE_BLOB_SIZE=104857601 RELEASE_ASSETS='["contract/schema.graphql"]' ASSET_STATE_ROOT="$work/runner/validation" GITHUB_OUTPUT="$work/output" bash -euo pipefail "$work/assets.sh" >/dev/null 2>&1); then
  echo "FAIL - accepted an asset over 100 MiB" >&2; exit 1
fi
echo "ok - rejects an asset over 100 MiB"
if (cd "$work/repo" && PATH="$work/bin:$PATH" REAL_GIT="$real_git" FAKE_BLOB_SIZE=94371840 RELEASE_ASSETS='["contract/schema.graphql","contract/schema.sha256","other/schema.graphql"]' ASSET_STATE_ROOT="$work/runner/validation" GITHUB_OUTPUT="$work/output" bash -euo pipefail "$work/assets.sh" >/dev/null 2>&1); then
  echo "FAIL - accepted assets over 250 MiB total" >&2; exit 1
fi
echo "ok - rejects assets over 250 MiB total"
echo "All tests passed."
