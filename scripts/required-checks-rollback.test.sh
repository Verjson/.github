#!/usr/bin/env bash
# shellcheck disable=SC2015
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fails=0
pass() { printf 'ok   - %s\n' "$1"; }
fail() { printf 'FAIL - %s\n' "$1"; fails=$((fails + 1)); }

bundle="$tmp/bundle"; remote="$tmp/remote"
mkdir -p "$bundle/scripts" "$bundle/.github" "$remote/scripts" "$remote/.github" "$tmp/bin"
cp "$here/required-checks-rollback.sh" "$bundle/scripts/required-checks-rollback.sh"
cp "$here/../.github/required-check-contract.json" "$bundle/.github/required-check-contract.json"
cp "$bundle/scripts/required-checks-rollback.sh" "$remote/scripts/required-checks-rollback.sh"
cp "$bundle/.github/required-check-contract.json" "$remote/.github/required-check-contract.json"
git -C "$bundle" init -q
recovery_dir="$bundle/.git/ruleset-recovery"; mkdir -p "$recovery_dir"; chmod 700 "$recovery_dir"

cat >"$tmp/preimage.json" <<'JSON'
{"name":"core-checks-node","target":"branch","enforcement":"active","bypass_actors":[],"conditions":{"ref_name":{"include":["~DEFAULT_BRANCH"],"exclude":[]},"repository_property":{"include":[],"exclude":[]}},"rules":[{"type":"required_status_checks","parameters":{"required_status_checks":[{"context":"ci / build-test"}],"strict_required_status_checks_policy":false,"do_not_enforce_on_create":true}}]}
JSON
jq '(.rules[0].parameters.required_status_checks) += [{"context":"changelog-contract"}]' "$tmp/preimage.json" >"$tmp/intended.json"
jq -n --argjson preimage "$(cat "$tmp/preimage.json")" --argjson intended "$(cat "$tmp/intended.json")" '{schema_version:1,organization:"Verjson",ruleset_id:20515817,ruleset_name:"core-checks-node",captured_at:"2026-08-11T00:00:00Z",preimage:$preimage,intended:$intended,selected:[]}' >"$recovery_dir/recovery.json"
chmod 600 "$recovery_dir/recovery.json"
cp "$tmp/intended.json" "$tmp/live.json"

cat >"$tmp/bin/gh" <<'GH'
#!/usr/bin/env bash
case "$*" in
  *"--method PUT"*) args=("$@"); for ((i=0;i<${#args[@]};i++)); do [ "${args[$i]}" = --input ] && cp "${args[$((i+1))]}" "$LIVE"; done; exit 0 ;;
  *"repos/Verjson/.github/contents/"*) endpoint="${2#*contents/}"; path="${endpoint%%\?*}"; cat "$REMOTE/$path" ;;
  *"repos/Verjson/.github") printf '{"default_branch":"main"}\n' ;;
  *"orgs/Verjson/rulesets/20515817"*) cat "$LIVE" ;;
  *) exit 64 ;;
esac
GH
chmod +x "$tmp/bin/gh"
export PATH="$tmp/bin:$PATH" LIVE="$tmp/live.json" REMOTE="$remote"
run() { ( RCA_ORG=Verjson RCA_RECOVERY_FILE="$recovery_dir/recovery.json" RCA_ACK=rollback-issue-731-core-checks-node "$bundle/scripts/required-checks-rollback.sh" >"$tmp/out" 2>&1; echo "rc=$?" ); }

rc="$(run)"
{ [ "$rc" = rc=0 ] && grep -q rolled-back-and-verified "$tmp/out" &&
  cmp -s <(jq -S -c . "$LIVE") <(jq -S -c . "$tmp/preimage.json"); } \
  && pass "rollback restores and verifies the exact protected preimage" || {
    sed 's/^/       /' "$tmp/out"
    fail "valid rollback failed ($rc)"
  }

cp "$tmp/intended.json" "$LIVE"; chmod 644 "$recovery_dir/recovery.json"
rc="$(run)"
{ [ "$rc" = rc=2 ] && grep -q artifact-permissions-invalid "$tmp/out"; } \
  && pass "rollback rejects an unprotected recovery artifact" || fail "unprotected artifact was accepted ($rc)"

chmod 600 "$recovery_dir/recovery.json"; cp "$tmp/preimage.json" "$LIVE"
rc="$(run)"
{ [ "$rc" = rc=2 ] && grep -q live-state-does-not-match-artifact "$tmp/out"; } \
  && pass "rollback never overwrites live state that moved beyond the intended image" || fail "stale rollback overwrote live drift ($rc)"

echo
if [ "$fails" -eq 0 ]; then echo "All tests passed."; else echo "$fails test(s) failed."; exit 1; fi
