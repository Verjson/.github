#!/usr/bin/env bash
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$here/../.." && pwd)"
release_workflow="$repo_root/.github/workflows/node-release.yml"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

extract_block() {
  local begin="$1" end="$2" output="$3"
  awk -v begin="$begin" -v end="$end" '
    index($0, begin) { active = 1 }
    active { sub(/^          /, ""); print }
    index($0, end) { exit }
  ' "$release_workflow" >"$output"
  bash -n "$output"
}

extract_block RESTART_SAFE_NPM_PUBLISH_BEGIN RESTART_SAFE_NPM_PUBLISH_END "$work/publish.sh"
extract_block RESTART_SAFE_GH_RELEASE_BEGIN RESTART_SAFE_GH_RELEASE_END "$work/release-notes.sh"
extract_block RELEASE_PREPARE_PACKAGES_BEGIN RELEASE_PREPARE_PACKAGES_END "$work/prepare.sh"

mkdir -p "$work/bin" "$work/repo/CHANGELOG" "$work/repo/compat" "$work/repo/scripts" "$work/state"
printf '%s\n' notes >"$work/repo/CHANGELOG/v1.2.3.md"
cat >"$work/repo/scripts/release-prepare-packages.sh" <<'HOOK'
#!/usr/bin/env bash
set -euo pipefail
[ "$1" = 1.2.3 ]
[ -z "${NODE_AUTH_TOKEN:-}" ]
touch "$TEST_STATE/prepared"
HOOK
chmod +x "$work/repo/scripts/release-prepare-packages.sh"

cat >"$work/bin/npm" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
command="$1"
shift
case "$command" in
  version) ;;
  pack)
    case "${PACK_MODE:-matching}:$1" in
      multi:.)
        touch acme-pkg-1.2.3.tgz
        printf '%s\n' '[{"name":"@acme/pkg","version":"1.2.3","integrity":"sha512-expected","filename":"acme-pkg-1.2.3.tgz"},{"name":"@acme/other","version":"1.2.3","integrity":"sha512-other","filename":"acme-other-1.2.3.tgz"}]'
        ;;
      wrong-version:.)
        touch acme-pkg-9.9.9.tgz
        printf '%s\n' '[{"name":"@acme/pkg","version":"9.9.9","integrity":"sha512-expected","filename":"acme-pkg-9.9.9.tgz"}]'
        ;;
      *:./compat)
        touch acme-compat-1.2.3.tgz
        printf '%s\n' '[{"name":"@acme/compat","version":"1.2.3","integrity":"sha512-compat","filename":"acme-compat-1.2.3.tgz"}]'
        ;;
      *:.)
        touch acme-pkg-1.2.3.tgz
        printf '%s\n' '[{"name":"@acme/pkg","version":"1.2.3","integrity":"sha512-expected","filename":"acme-pkg-1.2.3.tgz"}]'
        ;;
    esac
    ;;
  publish)
    case "$1" in
      *compat*) state="$TEST_STATE/registry-compat" ;;
      *) state="$TEST_STATE/registry-root" ;;
    esac
    if [ -e "$state" ]; then exit 1; fi
    touch "$state"
    ;;
  view)
    [ "${AUTH_FAIL:-0}" != 1 ] || exit 1
    [ "${NETWORK_FAIL:-0}" != 1 ] || exit 1
    case "${VIEW_MODE:-matching}:$1" in
      matching:*compat*) printf '%s\n' '{"name":"@acme/compat","version":"1.2.3","dist":{"integrity":"sha512-compat"}}' ;;
      matching:*) printf '%s\n' '{"name":"@acme/pkg","version":"1.2.3","dist":{"integrity":"sha512-expected"}}' ;;
      mismatch:*) printf '%s\n' '{"name":"@acme/pkg","version":"1.2.3","dist":{"integrity":"sha512-other"}}' ;;
      spoof:*) printf '%s\n' '{"name":"@attacker/pkg","version":"1.2.3","dist":{"integrity":"sha512-expected"}}' ;;
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
  ( cd "$work/repo" && PATH="$work/bin:$PATH" TEST_STATE="$work/state" VERSION=v1.2.3 \
      bash -euo pipefail "$work/prepare.sh" && \
    PATH="$work/bin:$PATH" TEST_STATE="$work/state" \
      REQUESTED_TAG=v1.2.3 NODE_AUTH_TOKEN=test PACKAGE_DIRS_JSON='[".","compat"]' \
      VIEW_MODE="${VIEW_MODE:-}" PACK_MODE="${PACK_MODE:-matching}" \
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
for expected_state in registry-root registry-compat prepared github-release; do
  [ -e "$work/state/$expected_state" ] || {
    echo "FAIL - partial-success rerun did not create $expected_state" >&2
    exit 1
  }
done
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
  [ ! -e "$work/state/registry-root" ] && [ ! -e "$work/state/registry-compat" ] || {
    echo "FAIL - $mode npm pack metadata reached publication" >&2
    exit 1
  }
  echo "ok - publication rejects $mode npm pack metadata before registry mutation"
done

for mode in mismatch spoof; do
  rm -rf "$work/state"; mkdir -p "$work/state"; touch "$work/state/registry-root"
  if VIEW_MODE="$mode" run_publish >/dev/null 2>&1; then
    echo "FAIL - rerun accepted $mode registry metadata" >&2
    exit 1
  fi
  echo "ok - rerun rejects $mode registry metadata"
done

rm -rf "$work/state"; mkdir -p "$work/state"; touch "$work/state/registry-root"
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
