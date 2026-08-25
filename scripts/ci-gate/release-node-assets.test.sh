#!/usr/bin/env bash
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
workflow="$root/.github/workflows/node-release.yml"
work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT

awk '
  /BOUNDED_RELEASE_ASSETS_BEGIN/ { active = 1 }
  active { sub(/^          /, ""); print }
  /BOUNDED_RELEASE_ASSETS_END/ { exit }
' "$workflow" >"$work/assets.sh"
bash -n "$work/assets.sh"
awk '
  /RESTART_SAFE_GH_RELEASE_BEGIN/ { active = 1 }
  active { sub(/^          /, ""); print }
  /RESTART_SAFE_GH_RELEASE_END/ { exit }
' "$workflow" >"$work/publish.sh"
bash -n "$work/publish.sh"

mkdir -p "$work/repo/contract" "$work/runner"
printf '%s\n' 'tagged schema' >"$work/repo/contract/schema.graphql"
printf '%s\n' 'tagged digest' >"$work/repo/contract/schema.sha256"
git -C "$work/repo" init -q
git -C "$work/repo" config user.name test
git -C "$work/repo" config user.email test@example.invalid
git -C "$work/repo" add contract/schema.graphql contract/schema.sha256
git -C "$work/repo" commit -qm fixture

run_assets() {
  (cd "$work/repo" && RELEASE_ASSETS="$1" RUNNER_TEMP="$work/runner" bash -euo pipefail "$work/assets.sh")
}
rejects() {
  local name="$1" value="$2"
  if run_assets "$value" >"$work/reject.out" 2>&1; then
    echo "FAIL - accepted $name" >&2
    exit 1
  fi
  echo "ok - rejects $name"
}

run_assets '[]'
[ ! -s "$work/runner/verjson-release-assets.paths" ]
echo "ok - empty opt-in stages no assets"

printf '%s\n' 'hostile workspace bytes' >"$work/repo/contract/schema.graphql"
run_assets '["contract/schema.graphql","contract/schema.sha256"]'
grep -qxF 'tagged schema' "$work/runner/verjson-release-assets/schema.graphql"
grep -qxF 'tagged digest' "$work/runner/verjson-release-assets/schema.sha256"
echo "ok - staged upload bytes come from the immutable HEAD tree"
git -C "$work/repo" restore contract/schema.graphql

mkdir -p "$work/repo/CHANGELOG" "$work/bin" "$work/state"
printf '%s\n' notes >"$work/repo/CHANGELOG/v1.2.3.md"
cat >"$work/bin/gh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
[ "$1" = release ]
case "$2" in
  view)
    [ -e "$TEST_STATE/release" ] || exit 1
    printf '%s\n' v1.2.3
    ;;
  create)
    touch "$TEST_STATE/release"
    printf '%s\n' create >>"$TEST_STATE/calls"
    ;;
  edit) printf '%s\n' edit >>"$TEST_STATE/calls" ;;
  upload)
    [ "${@: -1}" = --clobber ]
    printf 'upload' >>"$TEST_STATE/calls"
    printf '\t%s' "${@:3}" >>"$TEST_STATE/calls"
    printf '\n' >>"$TEST_STATE/calls"
    ;;
  *) exit 90 ;;
esac
STUB
chmod +x "$work/bin/gh"
run_publish() {
  (cd "$work/repo" && PATH="$work/bin:$PATH" TEST_STATE="$work/state" \
    RUNNER_TEMP="$work/runner" VERSION=v1.2.3 GH_TOKEN=test \
    GITHUB_SERVER_URL=https://github.com GITHUB_REPOSITORY=Verjson/example \
    bash -euo pipefail "$work/publish.sh")
}
run_publish
run_publish
[ "$(grep -c '^upload' "$work/state/calls")" -eq 2 ]
grep -q '^create$' "$work/state/calls"
grep -q '^edit$' "$work/state/calls"
grep -q 'schema.graphql.*schema.sha256.*--clobber' "$work/state/calls"
echo "ok - create and resume both reconcile the complete tagged asset set with clobber"

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
for index in $(seq 1 17); do
  many="${many}${index:+,}\"asset-$index.txt\""
done
many="${many/[,/[}]"
many="$many]"
rejects 'more than 16 assets' "$many"

real_git="$(command -v git)"
mkdir -p "$work/bin"
cat >"$work/bin/git" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
if [ "$1" = cat-file ] && [ "$2" = -s ]; then
  printf '%s\n' "$FAKE_BLOB_SIZE"
else
  exec "$REAL_GIT" "$@"
fi
STUB
chmod +x "$work/bin/git"
if (cd "$work/repo" && PATH="$work/bin:$PATH" REAL_GIT="$real_git" FAKE_BLOB_SIZE=104857601 \
    RELEASE_ASSETS='["contract/schema.graphql"]' RUNNER_TEMP="$work/runner" \
    bash -euo pipefail "$work/assets.sh" >/dev/null 2>&1); then
  echo "FAIL - accepted an asset over 100 MiB" >&2
  exit 1
fi
echo "ok - rejects an asset over 100 MiB"

if (cd "$work/repo" && PATH="$work/bin:$PATH" REAL_GIT="$real_git" FAKE_BLOB_SIZE=94371840 \
    RELEASE_ASSETS='["contract/schema.graphql","contract/schema.sha256","other/schema.graphql"]' \
    RUNNER_TEMP="$work/runner" bash -euo pipefail "$work/assets.sh" >/dev/null 2>&1); then
  echo "FAIL - accepted assets over 250 MiB total" >&2
  exit 1
fi
echo "ok - rejects assets over 250 MiB total"

echo "All tests passed."
