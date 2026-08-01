#!/usr/bin/env bash
# Generate a consumer's thin `ai-privileged-merge.yml` caller.
#
# Generated, not hand-written, because several details fail SILENTLY when wrong:
# the job key, the `uses:` target, and the values passed in `with:`. The
# reasoning lives in docs/decisions/0042-privileged-merge-reusable-split.
#
# Usage: gen-privileged-merge-caller.sh '<runner-labels-json>'
#   scripts/gen-privileged-merge-caller.sh '["ubuntu-24.04"]' > .github/workflows/ai-privileged-merge.yml
set -euo pipefail

# The target is FIXED, not a parameter. It IS the trust anchor: the canonical
# workflow validates provenance against Verjson/.github@main at runtime, so a
# caller pointing anywhere else — or at a frozen SHA — silently opts out of the
# guarantees this file exists to deliver while still carrying merge authority.
#
# An earlier revision accepted a `ref` argument. It injected arbitrary YAML into
# the job body (a ref of $'main\n    if: false' disabled merge authority
# outright) and slipped past the pin guard, which inspects only the `uses:`
# line. Removed rather than validated: its sole legitimate value was a SHA, and
# ADR 0042 forbids exactly that.
readonly TARGET="Verjson/.github/.github/workflows/ai-privileged-merge.yml@main"

runner_labels="${1:?usage: gen-privileged-merge-caller.sh '<runner-labels-json>'}"

command -v jq >/dev/null 2>&1 || { echo "jq is required" >&2; exit 2; }

# Charset-restricted, not merely well-formed JSON. A label containing a quote is
# valid JSON, passes a naive type check, then emits YAML GitHub cannot parse —
# at exit 0, with no warning. A value like ${{ secrets.X }} is likewise valid
# JSON and would expand a secret into a workflow input.
jq -e 'type == "array" and length > 0
       and all(.[]; type == "string" and test("^[A-Za-z0-9._-]+$"))' \
  <<<"$runner_labels" >/dev/null 2>&1 \
  || { printf 'runner_labels must be a non-empty JSON array of [A-Za-z0-9._-] strings, got: %s\n' "$runner_labels" >&2; exit 2; }

emit() {
  cat <<YAML
# GENERATED FILE — do not edit by hand.
# Regenerate with:
#   scripts/gen-privileged-merge-caller.sh '$runner_labels' > .github/workflows/ai-privileged-merge.yml
#
# Thin caller for the canonical privileged merge (Verjson/.github). All trust
# logic lives there; nothing here may re-implement it.
name: AI privileged merge

on:
  pull_request_target:
    types: [opened, reopened, ready_for_review, synchronize, labeled, unlabeled]
  workflow_dispatch:
    inputs:
      pr_number:
        required: true
        type: string
      expected_head_sha:
        required: true
        type: string
      source_run_id:
        required: true
        type: string

permissions:
  contents: read

# Deliberately NOT the canonical workflow's group name, and keyed by event so
# the dispatched continuation cannot cancel the pull_request_target check and
# leave a red mark on a merged PR (ADR 0039).
concurrency:
  group: ai-privileged-merge-call-\${{ github.event.pull_request.number || inputs.pr_number }}-\${{ github.event_name }}
  cancel-in-progress: true

jobs:
  # The job key is CONTRACTUAL: the published check name is
  # "<caller job> / <callee job>" and both workflows exclude that shape.
  # Renaming it makes the gate wait on its own continuation.
  privileged_merge:
    uses: ${TARGET}
    # Explicit rather than \`inherit\`: the caller grants exactly one secret
    # instead of its entire store to a workflow that floats on @main.
    secrets:
      ORG_ADMIN_TOKEN: \${{ secrets.ORG_ADMIN_TOKEN }}
    with:
      pr_number: \${{ github.event.pull_request.number || inputs.pr_number }}
      # The event value MUST win here: on pull_request_target it is the
      # anti-TOCTOU binding to the head the gate actually attested.
      expected_head_sha: \${{ github.event.pull_request.head.sha || inputs.expected_head_sha }}
      source_run_id: \${{ inputs.source_run_id }}
      runner_labels: '${runner_labels}'
YAML
}

# Never hand an operator a file that does not parse. The premise of generating
# this at all is that they should not be able to receive a silent footgun.
out="$(emit)"
if command -v python3 >/dev/null 2>&1 && python3 -c 'import yaml' 2>/dev/null; then
  printf '%s\n' "$out" | python3 -c 'import sys, yaml; yaml.safe_load(sys.stdin)' 2>/dev/null \
    || { echo "internal error: generated caller is not valid YAML; refusing to emit" >&2; exit 3; }
fi
printf '%s\n' "$out"
