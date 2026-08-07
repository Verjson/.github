#!/usr/bin/env bash
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$here/../.." && pwd)"
generator="$repo_root/scripts/gen-changelog-caller.sh"
sha="$(git -C "$repo_root" rev-parse HEAD)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

bash "$generator" release-node "$sha" --scope @acme >"$work/release.yml"

extract_block() {
  local begin="$1" end="$2" output="$3"
  awk -v begin="$begin" -v end="$end" '
    index($0, begin) { active = 1 }
    active { sub(/^          /, ""); print }
    index($0, end) { exit }
  ' "$work/release.yml" >"$output"
  bash -n "$output"
}

extract_block RESTART_SAFE_NPM_PUBLISH_BEGIN RESTART_SAFE_NPM_PUBLISH_END "$work/publish.sh"
extract_block RESTART_SAFE_GH_RELEASE_BEGIN RESTART_SAFE_GH_RELEASE_END "$work/release-notes.sh"

mkdir -p "$work/bin" "$work/repo/CHANGELOG" "$work/state"
printf '%s\n' notes >"$work/repo/CHANGELOG/v1.2.3.md"

cat >"$work/bin/npm" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
command="$1"
shift
case "$command" in
  pack)
    touch acme-pkg-1.2.3.tgz
    case "${PACK_MODE:-matching}" in
      matching)
        printf '%s\n' '[{"name":"@acme/pkg","version":"1.2.3","integrity":"sha512-expected","filename":"acme-pkg-1.2.3.tgz"}]'
        ;;
      multi)
        printf '%s\n' '[{"name":"@acme/pkg","version":"1.2.3","integrity":"sha512-expected","filename":"acme-pkg-1.2.3.tgz"},{"name":"@acme/other","version":"1.2.3","integrity":"sha512-other","filename":"acme-other-1.2.3.tgz"}]'
        ;;
      wrong-version)
        printf '%s\n' '[{"name":"@acme/pkg","version":"9.9.9","integrity":"sha512-expected","filename":"acme-pkg-9.9.9.tgz"}]'
        ;;
    esac
    ;;
  publish)
    if [ -e "$TEST_STATE/registry" ]; then exit 1; fi
    touch "$TEST_STATE/registry"
    ;;
  whoami)
    [ "${AUTH_FAIL:-0}" != 1 ] || exit 1
    printf '%s\n' test-user
    ;;
  view)
    [ "${NETWORK_FAIL:-0}" != 1 ] || exit 1
    case "${VIEW_MODE:-matching}" in
      matching) printf '%s\n' '{"name":"@acme/pkg","version":"1.2.3","dist":{"integrity":"sha512-expected"}}' ;;
      mismatch) printf '%s\n' '{"name":"@acme/pkg","version":"1.2.3","dist":{"integrity":"sha512-other"}}' ;;
      spoof) printf '%s\n' '{"name":"@attacker/pkg","version":"1.2.3","dist":{"integrity":"sha512-expected"}}' ;;
    esac
    ;;
  *) exit 90 ;;
esac
STUB

cat >"$work/bin/gh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
[ "$1" = release ]
case "$2" in
  view)
    [ -e "$TEST_STATE/github-release" ] || exit 1
    printf '%s\n' v1.2.3
    ;;
  create)
    [ "${GH_CREATE_FAIL:-0}" != 1 ] || exit 1
    touch "$TEST_STATE/github-release"
    ;;
  edit) [ -e "$TEST_STATE/github-release" ] ;;
  *) exit 90 ;;
esac
STUB
chmod +x "$work/bin/npm" "$work/bin/gh"

run_publish() {
  ( cd "$work/repo" && PATH="$work/bin:$PATH" TEST_STATE="$work/state" \
      VERSION=v1.2.3 NODE_AUTH_TOKEN=test VIEW_MODE="${VIEW_MODE:-}" \
      PACK_MODE="${PACK_MODE:-matching}" \
      AUTH_FAIL="${AUTH_FAIL:-0}" NETWORK_FAIL="${NETWORK_FAIL:-0}" \
      bash -euo pipefail "$work/publish.sh" )
}
run_notes() {
  ( cd "$work/repo" && PATH="$work/bin:$PATH" TEST_STATE="$work/state" \
      VERSION=v1.2.3 GH_TOKEN=test "$@" bash -euo pipefail "$work/release-notes.sh" )
}

run_publish
if run_notes env GH_CREATE_FAIL=1; then
  echo "FAIL - simulated GitHub Release failure unexpectedly succeeded" >&2
  exit 1
fi
run_publish
run_notes env GH_CREATE_FAIL=0
[ -e "$work/state/registry" ] && [ -e "$work/state/github-release" ]
echo "ok - npm success plus GitHub Release failure completes safely on rerun"
run_publish
run_notes env GH_CREATE_FAIL=0
echo "ok - a fully completed release rerun reconciles without rewriting package or tag"

for mode in multi wrong-version; do
  rm -rf "$work/state"; mkdir -p "$work/state"
  if PACK_MODE="$mode" run_publish >/dev/null 2>&1; then
    echo "FAIL - publication accepted $mode npm pack metadata" >&2
    exit 1
  fi
  [ ! -e "$work/state/registry" ] || {
    echo "FAIL - $mode npm pack metadata reached publication" >&2
    exit 1
  }
  echo "ok - publication rejects $mode npm pack metadata before registry mutation"
done

for mode in mismatch spoof; do
  rm -rf "$work/state"; mkdir -p "$work/state"; touch "$work/state/registry"
  if VIEW_MODE="$mode" run_publish >/dev/null 2>&1; then
    echo "FAIL - rerun accepted $mode registry metadata" >&2
    exit 1
  fi
  echo "ok - rerun rejects $mode registry metadata"
done

rm -rf "$work/state"; mkdir -p "$work/state"; touch "$work/state/registry"
if AUTH_FAIL=1 run_publish >/dev/null 2>&1; then
  echo "FAIL - rerun accepted unproven registry authorization" >&2
  exit 1
fi
echo "ok - rerun fails closed when registry authorization cannot be proven"
if NETWORK_FAIL=1 run_publish >/dev/null 2>&1; then
  echo "FAIL - rerun accepted unavailable registry state" >&2
  exit 1
fi
echo "ok - rerun fails closed when registry metadata is unavailable"
