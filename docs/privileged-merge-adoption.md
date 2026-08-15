# Privileged merge adoption

Adopt privileged terminal promotion only through the canonical generator. The
required-check policy is repository-specific reviewed code; do not store it in an
organization or repository variable.

1. Read the effective rules for the default branch and list every non-promotion
   required status-check context.
2. For each context, identify a recent completed pull-request job that publishes
   the exact name. Record its GitHub App ID and the owning active Actions workflow's
   repository-local ID and path.
3. Review a compact JSON array with exactly these keys for every entry:

   ```json
   [{"name":"<exact-check>","app_id":123,"workflow_id":456,"workflow_path":".github/workflows/ci.yml"}]
   ```

4. Generate both callers at one immutable canonical contract SHA. The policy argument
   must be identical in both commands:

   ```bash
   scripts/gen-privileged-merge-caller.sh "$contract_sha" "$required_checks" > .github/workflows/ai-privileged-merge.yml
   scripts/gen-privileged-merge-caller.sh "$contract_sha" --retry "$workflow_names" "$required_checks" > .github/workflows/ai-promotion-retry.yml
   ```

5. Review the generated diff, run the generated caller contract tests, and let
   `privileged-merge-conformance.yml` byte-compare both callers, bind retry names to
   workflow IDs, compare each required context with its native `integration_id`, and
   verify the merged workflow/job/App evidence. A missing, ambiguous, or stale
   identity is a failed adoption, not a runtime configuration task.

When a required context, job name, App, workflow ID, or workflow path changes, update
the policy and regenerate both callers in the same pull request as the workflow or
ruleset adoption. Keep the existing path working until its replacement has produced
conformance evidence. Never remove exact-head, receipt, hold, same-owner, or workflow
provenance checks to make adoption pass.
