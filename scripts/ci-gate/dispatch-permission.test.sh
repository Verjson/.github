#!/usr/bin/env bash
set -uo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
wf="$root/.github/workflows/ai-review-merge.yml"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fails=0
pass() { printf 'ok   - %s\n' "$1"; }
fail() { printf 'FAIL - %s\n' "$1"; fails=$((fails + 1)); }

gate="$(awk '/^  gate:/{cap=1} cap&&/^  dispatch-merge:/{exit} cap{print}' "$wf")"
dispatch="$(awk '/^  dispatch-merge:/{cap=1} cap{print}' "$wf")"

grep -q '^      actions: read$' <<<"$gate" \
  && grep -q '^      checks: read$' <<<"$gate" \
  && grep -q '^      statuses: read$' <<<"$gate" \
  && ! grep -q '^      actions: write$' <<<"$gate" \
  && ! grep -q '^      checks: write$' <<<"$gate" \
  && ! grep -q '^      statuses: write$' <<<"$gate" \
  && pass "PR checkout/review gate has actions/checks/statuses read only" \
  || fail "PR checkout/review gate permission placement drifted"
[ "$(grep -c '^      checks: read$' "$wf")" -eq 1 ] \
  && [ "$(grep -c '^      statuses: read$' "$wf")" -eq 1 ] \
  && ! grep -qE '^      checks: (read|write)$' <<<"$dispatch" \
  && ! grep -qE '^      statuses: (read|write)$' <<<"$dispatch" \
  && pass "checks/statuses read permissions are isolated to the PR review gate" \
  || fail "checks/statuses permission escaped the PR review gate"
[ "$(grep -c '^      actions: write$' "$wf")" -eq 1 ] \
  && grep -q '^      contents: read$' <<<"$dispatch" \
  && pass "only dispatch job has minimum contents/read + actions/write" \
  || fail "dispatch permissions are duplicated or over-broad"
if grep -qE 'uses:|actions/(checkout|cache|upload-artifact|download-artifact)|\beval\b|^[[:space:]]*(source|\.)[[:space:]]|github\.event\.pull_request\.(title|body)' <<<"$dispatch"; then
  fail "dispatch job can consume/execute PR-controlled content"
else
  pass "dispatch job has no checkout, artifact/cache, eval/source, or PR prose"
fi
grep -q 'needs: \[preflight, gate\]' <<<"$dispatch" \
  && grep -q "if: needs.gate.result == 'success'" <<<"$dispatch" \
  && pass "dispatch requires successful gate and preflight identity" \
  || fail "dispatch dependency/condition drifted"

bootstrap="$tmp/bootstrap.sh"
awk '
  $0 == "      - name: Ensure pinned GitHub CLI" { seen=1 }
  seen && $0 == "        run: |" { cap=1; next }
  cap {
    if (substr($0,1,10) == "          ") { print substr($0,11); next }
    if ($0 ~ /^[[:space:]]*$/) { print ""; next }
    exit
  }
' "$wf" >"$bootstrap"
[ -s "$bootstrap" ] \
  || { echo "FAIL - could not extract GitHub CLI bootstrap"; exit 1; }

# Exercise the shipped bootstrap with a PATH that deliberately contains no gh.
# Tool stubs avoid a network dependency while asserting the exact artifact,
# transport flags, checksum, architecture routing, and fail-closed behavior.
mkdir "$tmp/bootstrap-bin" "$tmp/bootstrap-root" "$tmp/runner-temp"
cat >"$tmp/bootstrap-bin/uname" <<'EOF'
#!/bin/bash
printf '%s\n' "$TEST_UNAME"
EOF
cat >"$tmp/bootstrap-bin/mktemp" <<'EOF'
#!/bin/bash
printf '%s\n' "$BOOTSTRAP_ROOT"
EOF
cat >"$tmp/bootstrap-bin/curl" <<'EOF'
#!/bin/bash
set -eu
printf '%s\n' "$*" >>"$CURL_LOG"
while [ "$#" -gt 0 ]; do
  if [ "$1" = "--output" ]; then
    shift
    : >"$1"
  fi
  shift
done
EOF
cat >"$tmp/bootstrap-bin/sha256sum" <<'EOF'
#!/bin/bash
IFS= read -r line
printf '%s\n' "$line" >"$SHA_LOG"
[ "${SHA_FAIL:-false}" = false ]
EOF
cat >"$tmp/bootstrap-bin/tar" <<'EOF'
#!/bin/bash
/bin/mkdir -p "$BOOTSTRAP_ROOT/gh_2.78.0_linux_${EXPECTED_ARCH}/bin"
printf '#!/bin/bash\nexit 0\n' >"$BOOTSTRAP_ROOT/gh_2.78.0_linux_${EXPECTED_ARCH}/bin/gh"
/bin/chmod +x "$BOOTSTRAP_ROOT/gh_2.78.0_linux_${EXPECTED_ARCH}/bin/gh"
EOF
chmod +x "$tmp/bootstrap-bin/uname" "$tmp/bootstrap-bin/mktemp" \
  "$tmp/bootstrap-bin/curl" "$tmp/bootstrap-bin/sha256sum" \
  "$tmp/bootstrap-bin/tar"
ln -s /usr/bin/install "$tmp/bootstrap-bin/install"
ln -s /bin/rm "$tmp/bootstrap-bin/rm"

amd64_sha=ac309f70c5d6b122c82e6138ce82cb65ca5d8595cc09d11751fbc4e3907e1a05
arm64_sha=9e3ca75b227a5503f6ef92c4b8b6dbf94e34bfdd8069ac0f16b8739856ebba7b
run_bootstrap() {
  /bin/rm -rf "$tmp/bootstrap-root" "$tmp/runner-temp"
  mkdir "$tmp/bootstrap-root" "$tmp/runner-temp"
  : >"$tmp/github-path"
  : >"$tmp/curl.log"
  : >"$tmp/sha.log"
  PATH="$tmp/bootstrap-bin" \
    BOOTSTRAP_ROOT="$tmp/bootstrap-root" CURL_LOG="$tmp/curl.log" \
    SHA_LOG="$tmp/sha.log" SHA_FAIL="${SHA_FAIL:-false}" \
    TEST_UNAME="${TEST_UNAME:-x86_64}" EXPECTED_ARCH="${EXPECTED_ARCH:-amd64}" \
    GH_CLI_VERSION=2.78.0 GH_CLI_AMD64_SHA256="$amd64_sha" \
    GH_CLI_ARM64_SHA256="$arm64_sha" \
    RUNNER_TEMP="$tmp/runner-temp" GITHUB_PATH="$tmp/github-path" \
    /bin/bash "$bootstrap"
}

run_bootstrap \
  && [ -x "$tmp/runner-temp/gh" ] \
  && grep -qxF "$tmp/runner-temp" "$tmp/github-path" \
  && grep -qxF "$amd64_sha  $tmp/bootstrap-root/gh_2.78.0_linux_amd64.tar.gz" "$tmp/sha.log" \
  && grep -qxF -- "--fail --silent --show-error --location --output $tmp/bootstrap-root/gh_2.78.0_linux_amd64.tar.gz https://github.com/cli/cli/releases/download/v2.78.0/gh_2.78.0_linux_amd64.tar.gz" "$tmp/curl.log" \
  && pass "amd64 runner without gh downloads and verifies the pinned official artifact (#257)" \
  || fail "amd64 GitHub CLI bootstrap contract regressed (#257)"

TEST_UNAME=aarch64 EXPECTED_ARCH=arm64 run_bootstrap \
  && [ -x "$tmp/runner-temp/gh" ] \
  && grep -qxF "$arm64_sha  $tmp/bootstrap-root/gh_2.78.0_linux_arm64.tar.gz" "$tmp/sha.log" \
  && grep -qF 'https://github.com/cli/cli/releases/download/v2.78.0/gh_2.78.0_linux_arm64.tar.gz' "$tmp/curl.log" \
  && pass "arm64 runner selects and verifies the pinned arm64 artifact (#257)" \
  || fail "arm64 GitHub CLI bootstrap contract regressed (#257)"

if SHA_FAIL=true run_bootstrap; then
  fail "checksum rejection did not fail the bootstrap"
elif [ ! -e "$tmp/runner-temp/gh" ] && [ ! -s "$tmp/github-path" ]; then
  pass "checksum failure leaves no installed CLI or PATH mutation (#257)"
else
  fail "checksum failure left executable or PATH state behind (#257)"
fi

if TEST_UNAME=s390x run_bootstrap; then
  fail "unsupported runner architecture was accepted"
elif [ ! -e "$tmp/runner-temp/gh" ] && [ ! -s "$tmp/github-path" ] && [ ! -s "$tmp/curl.log" ]; then
  pass "unsupported runner architecture fails before download (#257)"
else
  fail "unsupported architecture did not fail closed before download (#257)"
fi

mkdir "$tmp/preinstalled-bin"
cat >"$tmp/preinstalled-bin/gh" <<'EOF'
#!/bin/bash
exit 0
EOF
chmod +x "$tmp/preinstalled-bin/gh"
: >"$tmp/github-path"
: >"$tmp/curl.log"
PATH="$tmp/preinstalled-bin" RUNNER_TEMP="$tmp/runner-temp" \
  GITHUB_PATH="$tmp/github-path" /bin/bash "$bootstrap" \
  && [ ! -s "$tmp/github-path" ] && [ ! -s "$tmp/curl.log" ] \
  && pass "preinstalled gh skips download, verification, and PATH mutation (#257)" \
  || fail "preinstalled gh did not take the no-bootstrap fast path (#257)"

script="$tmp/dispatch.sh"
awk '
  $0 == "      - name: Dispatch fixed trusted merge continuation" { seen=1 }
  seen && $0 == "        run: |" { cap=1; next }
  cap {
    if (substr($0,1,10) == "          ") { print substr($0,11); next }
    if ($0 ~ /^[[:space:]]*$/) { print ""; next }
    exit
  }
' "$wf" >"$script"
mkdir "$tmp/bin"
cat >"$tmp/bin/gh" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = api ]; then
  [ "$2" = --paginate ] &&
    [ "$3" = repos/Verjson/example/actions/workflows ] &&
    [ "$4" = --jq ] &&
    [ "$5" = '.workflows[] | select(.path == ".github/workflows/ai-privileged-merge.yml") | .path' ] ||
    exit 2
  [ "${API_FAILURE:-false}" = false ] || exit 1
  printf '%s' "${WORKFLOW_PATH-.github/workflows/ai-privileged-merge.yml}"
  [ -z "${WORKFLOW_PATH-.github/workflows/ai-privileged-merge.yml}" ] || printf '\n'
  exit 0
fi
if [ "$1 $2" = "workflow run" ]; then printf '%s\n' "$*" >>"$DISPATCH_LOG"; exit 0; fi
exit 2
EOF
chmod +x "$tmp/bin/gh"

run_case() {
  : >"$tmp/dispatch.log"
  : >"$tmp/dispatch.out"
  PATH="$tmp/bin:$PATH" DISPATCH_LOG="$tmp/dispatch.log" GH_TOKEN=token \
    GITHUB_REPOSITORY=Verjson/example TARGET_REPO="${1-Verjson/example}" \
    PR_NUMBER="${2-7}" EXPECTED_HEAD_SHA="${3-0123456789abcdef0123456789abcdef01234567}" \
    SOURCE_RUN_ID="${4-99}" WORKFLOW_PATH="${5-.github/workflows/ai-privileged-merge.yml}" \
    API_FAILURE="${6-false}" bash "$script" >"$tmp/dispatch.out" 2>&1
}
run_case && grep -q 'workflow run ai-privileged-merge.yml' "$tmp/dispatch.log" \
  && pass "validated identities dispatch only the fixed workflow" \
  || fail "valid trusted dispatch failed"
run_case 'Verjson/example' 7 0123456789abcdef0123456789abcdef01234567 99 '' \
  && [ ! -s "$tmp/dispatch.log" ] \
  && grep -q 'requires human merge' "$tmp/dispatch.out" \
  && pass "absent privileged continuation is a green manual-merge no-op" \
  || fail "absent privileged continuation did not preserve green validation"
run_case 'Verjson/example' 7 0123456789abcdef0123456789abcdef01234567 99 '' true \
  && fail "workflow-list API failure did not fail closed" \
  || pass "workflow-list API failure remains terminal"
for bad in repo pr head run workflow; do
  case "$bad" in
    repo) args=('Other/example') ;;
    pr) args=('Verjson/example' '7;echo forged') ;;
    head) args=('Verjson/example' 7 'main') ;;
    run) args=('Verjson/example' 7 0123456789abcdef0123456789abcdef01234567 '9;bad') ;;
    workflow) args=('Verjson/example' 7 0123456789abcdef0123456789abcdef01234567 99 '.github/workflows/other.yml') ;;
  esac
  run_case "${args[@]}" \
    && fail "forged $bad input dispatched" \
    || pass "forged $bad input fails closed"
done

[ "$fails" -eq 0 ] && { echo "All tests passed."; exit 0; }
echo "$fails test(s) failed."
exit 1
