#!/usr/bin/env bash
# AI-review follow-up from PR #949 (#951): no automated test exercised the
# stderr redaction path guarding the receipt-deletion step in
# ai-privileged-merge.yml. The step's terminal fragment -- the receipt
# deletion that runs after a confirmed merge -- is extracted from the shipped
# workflow (single source of truth, per house convention; see
# privileged-merge-pin.test.sh) and exercised against a stubbed `gh` that
# leaks an Authorization header on the DELETE call's stderr, the same shape
# arm-receipt.test.sh already uses for verify-arm-receipt.sh's own redaction.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$here/../.." && pwd)"
wf="$repo_root/.github/workflows/ai-privileged-merge.yml"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fails=0
pass() { printf 'ok   - %s\n' "$1"; }
fail() { printf 'FAIL - %s\n' "$1"; fails=$((fails + 1)); }

step_name="Attempt terminal merge from trusted metadata"
anchor="# The receipt has now served its purpose:"

extract_deletion_fragment() {
  local destination="$1"
  python3 - "$wf" "$step_name" "$anchor" >"$destination" <<'EXTRACT_PY'
import sys

import yaml

workflow = yaml.safe_load(open(sys.argv[1], encoding="utf-8"))
steps = workflow["jobs"]["privileged_merge"]["steps"]
matches = [step for step in steps if step.get("name") == sys.argv[2]]
if len(matches) != 1:
    raise SystemExit(f"expected exactly one {sys.argv[2]!r} step, found {len(matches)}")
script = matches[0].get("run")
if not isinstance(script, str) or not script.strip():
    raise SystemExit(f"{sys.argv[2]!r} has no non-empty run script")
anchor = sys.argv[3]
lines = script.splitlines()
start = next((i for i, line in enumerate(lines) if anchor in line), None)
if start is None:
    raise SystemExit(f"anchor {anchor!r} not found in {sys.argv[2]!r}")
fragment = "\n".join(lines[start:])
print("set -euo pipefail")
print(fragment)
EXTRACT_PY
}

script="$tmp/deletion.sh"
extract_deletion_fragment "$script" \
  && [ -s "$script" ] \
  && grep -qF 'sed -E' "$script" \
  && pass "the receipt-deletion fragment is found and extracted" \
  || { echo "FAIL - could not extract the deletion fragment from $wf"; exit 1; }

mkdir -p "$tmp/bin"
cat >"$tmp/bin/gh" <<'GH'
#!/usr/bin/env bash
case "$*" in
  *"--method DELETE"*"actions/artifacts/"*)
    printf 'authorization: token leaked-admin-token\nx-github-request-id: TEST:951\n' >&2
    exit 1 ;;
  *) echo "unexpected gh call: $*" >&2; exit 2 ;;
esac
GH
chmod +x "$tmp/bin/gh"

run_case() {
  PATH="$tmp/bin:$PATH" RUNNER_TEMP="$tmp/run" TARGET_REPO=Verjson/example \
    bash "$script" 2>&1
}

# --- deletion failure is non-fatal and redacts a leaked Authorization header -
mkdir -p "$tmp/run"
printf '8001\n' >"$tmp/run/arm-receipt-artifact-id"
out="$(run_case)"; status=$?
if [ "$status" -eq 0 ] \
    && grep -qF '::warning::failed to delete consumed arm receipt artifact 8001' <<<"$out" \
    && grep -qF 'x-github-request-id: TEST:951' <<<"$out" \
    && grep -qF 'authorization: token ***' <<<"$out" \
    && ! grep -qF 'leaked-admin-token' <<<"$out"; then
  pass "a failed artifact deletion is non-fatal and redacts a leaked Authorization header (#951)"
else
  fail "a failed artifact deletion leaked or mangled the Authorization header, or failed the step (exit $status): $out"
fi

[ "$fails" -eq 0 ] && { echo "All tests passed."; exit 0; }
echo "$fails test(s) failed."
exit 1
