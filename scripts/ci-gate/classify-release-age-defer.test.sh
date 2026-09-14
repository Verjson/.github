#!/usr/bin/env bash
# The merge gate's own release-age defer, in `ai-review-merge.yml`'s "Classify PR
# into a lane" step (Verjson/.github#1331).
#
# `internalChecksFilter: strict` withholds version candidates that miss
# `minimumReleaseAge`, but a Renovate *replacement* PR bypasses that filter and is
# raised immediately carrying a pending `renovate/stability-days` status. It cannot
# merge until the age elapses, so reviewing it burns a paid model call and a long
# gate-runner CI wait that re-burn on every rebase. The step therefore emits a lane
# no downstream job consumes.
#
# `#1329` deleted `required-workflow-provenance.test.sh`, which was the only file
# asserting this step's read of that status. `ci-eligibility.test.sh` mentions
# `renovate/stability-days` but covers the separate `node-ci.yml` CI-eligibility
# path, not this gate's own preflight; `dispatch-permission.test.sh` pins
# `statuses: read` on `preflight` structurally, which would catch the grant being
# removed but says nothing about what the step does when the read fails anyway.
#
# The fail-open is the load-bearing case and is deliberate, so it is pinned here
# rather than left implicit. Deferring is not a safety property: a defer suppresses
# a review, it does not authorize anything, and GitHub still blocks the merge on the
# genuinely-pending status regardless of what this step concludes. Failing closed on
# an unreadable status would instead stall every Renovate PR behind any transient
# 5xx or a lost scope, trading a wasted review for a silent delivery outage.
#
# House method: extract the shipped step's real `run:` block and drive it against a
# stubbed `gh`, so the test cannot drift from the workflow. Plain bash + python3 + jq.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
wf="$root/.github/workflows/ai-review-merge.yml"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fails=0
pass() { printf 'ok   - %s\n' "$1"; }
fail() { printf 'FAIL - %s\n' "$1"; fails=$((fails + 1)); }

python3 - "$wf" >"$tmp/classify.sh" <<'PY'
import sys

import yaml

document = yaml.safe_load(open(sys.argv[1], encoding="utf-8"))
steps = document["jobs"]["preflight"]["steps"]
matches = [s for s in steps if s.get("name") == "Classify PR into a lane"]
if len(matches) != 1 or not matches[0].get("run"):
    raise SystemExit("missing unique non-empty step: Classify PR into a lane")
run = matches[0]["run"]
if "renovate/stability-days" not in run:
    raise SystemExit("the classify step no longer reads renovate/stability-days")
print(run)
PY
[ -s "$tmp/classify.sh" ] || { echo "FAIL - could not extract the classify step from $wf"; exit 1; }

# The step must reach the status read on its own preflight permissions, not a
# privileged token: a defer decision may never be worth widening this job's scope.
if python3 - "$wf" <<'PY'
import sys

import yaml

document = yaml.safe_load(open(sys.argv[1], encoding="utf-8"))
step = next(s for s in document["jobs"]["preflight"]["steps"] if s.get("name") == "Classify PR into a lane")
assert step["env"]["GH_TOKEN"] == "${{ github.token }}", "classification must run on the event token"
assert document["jobs"]["preflight"]["permissions"]["statuses"] == "read", "preflight needs statuses: read to observe the age gate"
PY
then
  pass "the age-gate read runs on the event token under preflight's statuses: read"
else
  fail "the classify step's token or the preflight statuses grant drifted"
fi

mkdir -p "$tmp/bin"
cat >"$tmp/bin/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$CALLS"
case "$*" in
  "pr view "*) cat "$META_FILE" ;;
  "pr edit "*) : ;;
  api*/status*)
    [ "${STATUS_RC:-0}" -eq 0 ] || exit "$STATUS_RC"
    # Honor --jq the way `gh api` does: the step reads a count, not the payload,
    # so a stub that ignored the filter would not exercise the real comparison.
    filter='.'
    while [ "$#" -gt 0 ]; do
      [ "$1" = --jq ] && { filter="$2"; break; }
      shift
    done
    jq -r "$filter" "$STATUS_FILE" ;;
  *) echo "unexpected gh call: $*" >&2; exit 2 ;;
esac
STUB
chmod +x "$tmp/bin/gh"

# A files reader that records its own invocation: a defer must never pay for the
# paginated diff read the lane classifier would otherwise need.
cat >"$tmp/bin/read-pr-files" <<'STUB'
#!/usr/bin/env bash
printf 'read-pr-files\n' >>"$CALLS"
printf '[]\n'
STUB
chmod +x "$tmp/bin/read-pr-files"

HEAD_SHA=1111111111111111111111111111111111111111
export PATH="$tmp/bin:$PATH" CALLS="$tmp/calls" META_FILE="$tmp/meta.json" STATUS_FILE="$tmp/status.json"
printf '{"labels":[],"title":"chore(deps): bump widget","isDraft":false,"author":{"login":"renovate[bot]"},"headRefOid":"%s","baseRefName":"main"}\n' \
  "$HEAD_SHA" >"$META_FILE"

# status_fixture <state|none> — the commit status payload the age gate reads.
status_fixture() {
  case "$1" in
    none) printf '{"statuses":[]}\n' >"$STATUS_FILE" ;;
    *) printf '{"statuses":[{"context":"renovate/stability-days","state":"%s"}]}\n' "$1" >"$STATUS_FILE" ;;
  esac
}

run_classify() {
  : >"$CALLS"
  : >"$tmp/output"
  (
    export TARGET_REPO=Verjson/example PR_NUMBER=7
    export GITHUB_OUTPUT="$tmp/output"
    export GITHUB_EVENT_NAME="${EVENT_NAME-pull_request}"
    export EXPLICIT_REREVIEW=false
    export POLICY_DECODER="$root/scripts/ci-gate/review-policy-envelope.py"
    export PR_FILES_READER="$tmp/bin/read-pr-files"
    export REVIEW_CLASSIFIER="$root/scripts/ci-gate/classify-review-policy.py"
    bash "$tmp/classify.sh"
  ) >"$tmp/out" 2>&1
}

deferred() { grep -qx 'lane=defer' "$tmp/output"; }

status_fixture pending
if run_classify && deferred; then
  pass "a pending renovate/stability-days status defers the review"
else
  pass_reason="$(tail -1 "$tmp/out")"
  fail "pending age gate did not defer: $pass_reason"
fi
grep -qx 'model=none' "$tmp/output" \
  && pass "a deferred PR reserves no model" || fail "a deferred PR still selected a model"
grep -q 'renovate/stability-days' "$tmp/output" \
  && pass "the defer reason names the age gate that caused it" || fail "the defer reason is unattributable"
! grep -q '^read-pr-files$' "$CALLS" \
  && pass "a defer costs no paginated diff read" || fail "the defer still paid for the PR file read"

# --- the gate must not defer on anything other than a live pending age gate ----
for settled in success failure error none; do
  status_fixture "$settled"
  run_classify
  if deferred; then
    fail "a $settled age-gate status wrongly deferred the review"
  else
    pass "a $settled age-gate status does not defer"
  fi
done

# A pending status from some other context is not this gate.
printf '{"statuses":[{"context":"ci/other","state":"pending"}]}\n' >"$STATUS_FILE"
run_classify
deferred && fail "an unrelated pending status deferred the review" \
  || pass "an unrelated pending status does not defer"

# --- the documented fail-open ---------------------------------------------------
# Losing `statuses: read` (or any transient failure of that read) must leave the PR
# reviewable rather than stalled. Nothing is authorized by not deferring; the pending
# status still blocks the merge on GitHub's side.
status_fixture pending
if (export STATUS_RC=1; run_classify); then
  deferred && fail "an unreadable age-gate status deferred the review" \
    || pass "an unreadable age-gate status fails open to a normal review (deliberate)"
else
  fail "an unreadable age-gate status aborted classification instead of failing open"
fi

# --- workflow_dispatch forces a review past the gate ----------------------------
status_fixture pending
if (export EVENT_NAME=workflow_dispatch; run_classify); then
  deferred && fail "workflow_dispatch was still deferred by the age gate" \
    || pass "workflow_dispatch forces a review past a pending age gate"
else
  fail "workflow_dispatch classification failed"
fi
! grep -q '/status' "$CALLS" \
  && pass "workflow_dispatch does not read the age gate at all" \
  || fail "workflow_dispatch consumed a statuses read it cannot act on"

[ "$fails" -eq 0 ] && { echo "All tests passed."; exit 0; }
echo "$fails test(s) failed."
exit 1
