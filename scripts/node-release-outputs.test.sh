#!/usr/bin/env bash
# Exercises the node-release publication outputs (Verjson/.github#244): the
# workflow_call -> job -> step wiring, and the runner's behaviour against a
# stubbed semantic-release for every result shape it can be handed.
#
# The gate a consumer builds on this is "did a publish actually happen", so the
# cases that matter most are the ones where the runner must NOT claim it did.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/.." && pwd)"
workflow="$root/.github/workflows/node-release.yml"
runner="$root/.github/release-tooling/emit-release-outputs.mjs"
fails=0

pass() { printf 'ok   - %s\n' "$1"; }
fail() { printf 'FAIL - %s\n' "$1"; fails=$((fails + 1)); }

# --- wiring -----------------------------------------------------------------
# An output is only reachable by a caller if all three links exist; a job output
# wired to a step id that does not exist silently resolves to empty.
for name in new-release-published new-release-version; do
  { grep -qF "value: \${{ jobs.release.outputs.$name }}" "$workflow" \
    && grep -qF "$name: \${{ steps.publish.outputs.$name }}" "$workflow"; } \
    && pass "$name is exposed from the job through workflow_call" \
    || fail "$name is not wired from the publish step out to callers"
done

grep -qE '^        id: publish$' "$workflow" \
  && pass "the publish step carries the id the job outputs reference" \
  || fail "the publish step has no 'id: publish' for the job outputs to read"

grep -qF "compare against 'true' — never against 'false'" "$workflow" \
  && pass "the output description states the fail-closed comparison" \
  || fail "the output description omits the fail-closed comparison"

# --- runner behaviour -------------------------------------------------------
# Stub semantic-release rather than run a real release: this asserts the
# contract the runner keeps with whatever the API returns.
sandbox="$(mktemp -d)"
trap 'rm -rf -- "$sandbox"' EXIT
stub_dir="$sandbox/node_modules/semantic-release"
mkdir -p "$stub_dir"
cp "$runner" "$sandbox/emit-release-outputs.mjs"
printf '{"name":"semantic-release","version":"0.0.0-stub","type":"module","main":"index.js"}\n' \
  >"$stub_dir/package.json"

# Runs the runner against a stubbed API body. Echoes the exit status, and leaves
# the emitted output file at $sandbox/github-output.
run_case() {
  printf '%s\n' "$1" >"$stub_dir/index.js"
  : >"$sandbox/github-output"
  GITHUB_OUTPUT="$sandbox/github-output" node "$sandbox/emit-release-outputs.mjs" >/dev/null 2>&1
  printf '%s' "$?"
}

emitted() { cat "$sandbox/github-output"; }

status="$(run_case 'export default async () => ({ nextRelease: { version: "1.4.0" } });')"
{ [ "$status" -eq 0 ] \
  && grep -qxF 'new-release-published=true' <<<"$(emitted)" \
  && grep -qxF 'new-release-version=1.4.0' <<<"$(emitted)"; } \
  && pass "a published release reports true and its version" \
  || fail "a published release does not report true and its version"

status="$(run_case 'export default async () => false;')"
{ [ "$status" -eq 0 ] \
  && grep -qxF 'new-release-published=false' <<<"$(emitted)" \
  && grep -qxF 'new-release-version=' <<<"$(emitted)"; } \
  && pass "a no-op release reports false and an empty version" \
  || fail "a no-op release does not report false and an empty version"

# Failure modes: each must exit non-zero AND leave no 'true' behind, so a caller
# gating on == 'true' cannot act on a release that did not complete.
while IFS='|' read -r label body; do
  [ -n "$label" ] || continue
  status="$(run_case "$body")"
  { [ "$status" -ne 0 ] && ! grep -q 'new-release-published=true' <<<"$(emitted)"; } \
    && pass "$label fails the job without claiming a publication" \
    || fail "$label does not fail closed"
done <<'CASES'
a thrown release error|export default async () => { throw new Error("publish failed"); };
a result with no nextRelease|export default async () => ({});
a nextRelease with no version|export default async () => ({ nextRelease: {} });
a non-string version|export default async () => ({ nextRelease: { version: 42 } });
an empty version|export default async () => ({ nextRelease: { version: "" } });
an undefined result|export default async () => undefined;
CASES

# Without GITHUB_OUTPUT there is nowhere to report the result, so the runner must
# refuse before publishing rather than publish and drop the outcome on the floor.
printf '%s\n' 'export default async () => { throw new Error("must not run"); };' >"$stub_dir/index.js"
env -u GITHUB_OUTPUT node "$sandbox/emit-release-outputs.mjs" >/dev/null 2>&1 \
  && fail "the runner publishes even with no GITHUB_OUTPUT to report into" \
  || pass "the runner refuses to publish with no GITHUB_OUTPUT to report into"

if [ "$fails" -eq 0 ]; then
  echo "All tests passed."
  exit 0
fi
echo "$fails test(s) failed."
exit 1
