# 0200 — Temporarily authorize exact legacy review-App checks

- **Date:** 2026-09-22
- **Status:** Accepted
- **Related:** [ADR 0112](../0112-arm-authorization-checks-reach-a-terminal-state/README.md), [ADR 0199](../0199-authorization-checks-fail-without-review-app-credentials/README.md)
- **Issues:** [#1393](https://github.com/Verjson/.github/issues/1393), [#1540](https://github.com/Verjson/.github/issues/1540)
- **Supersedes (legacy-check completion permission only):** [ADR 0199](../0199-authorization-checks-fail-without-review-app-credentials/README.md)

## Context

ADR 0199 makes GitHub Actions the owner of newly created `AI review authorization` checks and keeps receipt-bound compatibility for older checks created by the review App. A queued review run can outlive a sibling job that waits for the `ai-review-app` environment. When that run completes, its workflow must terminalize the exact authorization check named by its receipt. The Actions token cannot update a check created by the review App.

## Decision

Keep Actions-owned checks as the only identity for new authorization receipts. During the tracked compatibility window, the review App token requests `checks:write`. The trusted workflow uses this token only to complete a legacy review-App-owned check. Before updating it, the workflow verifies the exact check ID, owner App ID and slug, check name, head SHA, receipt external ID, repository, PR, arm run and attempt, and details URL. The normal completion path updates that receipt-bound check only after authorization has been evaluated; the always-run fallback can only fail it. Unknown check owners fail closed.

The GitHub App permission itself is broader than one check ID: GitHub does not scope `checks:write` to a particular check. This exception therefore depends on the protected environment and trusted workflow enforcing the receipt and owner checks. It does not change the ownership of new checks or grant the review App permission to create authorization checks.

Remove this permission and the legacy-owner branches after issue #1540 verifies that no active receipt or adopter requires an App-owned authorization check.

## Consequences

- Queued legacy review runs can reach a terminal state without changing authorization identity or accepting an unbound check.
- The review App temporarily gains check write authority for every check in the target repository. The workflow limits its use to the validated receipt-bound check, but the GitHub permission does not enforce that narrower boundary.
- Issue #1540 tracks removal of the permission and compatibility code after the migration evidence is complete.
