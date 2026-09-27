---
date: 2026-09-23
issue: 1424
impact: patch
title: Report closing issues left open by App merges
---

The fallback now binds the target and every visible issue repository to an immutable database ID plus its current name, and rejects accessible cross-repository or identity-mismatched nodes. The retry resolver is explicitly downscoped without issue access; only the promotion job receives the `issues:read` authority needed for capture and reporting.

Pull-request and repository identity numbers now require exact positive JSON integers throughout live GraphQL reads and the ephemeral snapshot. Boolean, floating-point, string, null, zero, and negative lookalikes fail closed.

Terminal promotion now reports every caller-token-visible, same-repository GitHub-resolved closing issue that remains open after an App-authored merge while preserving the merge App's issue-mutation boundary.
Closing-reference capture also fails closed when distinct stable node identities claim the same repository-and-issue locator, and post-merge confirmation regression coverage proves a merged response for the wrong head cannot authorize receipt cleanup.

[ADR 0207](../docs/decisions/0207-withhold-issue-mutation-from-terminal-merge-app/README.md) records the reviewed decision and secret-free provisioning receipt. The fallback captures the scoped reference set before merge with caller-owned read authority, rejects accessible cross-repository nodes, re-reads the same set afterward, and treats missing evidence as a visible failure without mutating issues. Private cross-repository references that the repository-scoped token cannot see remain ordinary PM reconciliation work; the fallback does not claim completeness beyond its authority.

Arm-receipt deletion now runs in a dedicated secret-free job with the sole `actions:write` job permission. The privileged merge job remains at `actions:read`, exports only the validated artifact ID and terminal-success boolean after GitHub confirms the exact merged head, and cannot expose the merge App credential to cleanup. A later reporting failure preserves that confirmed cleanup authorization.

Runner-routing policy now inventories that one-minute, secret-free cleanup job as exact fixed-hosted provenance and evaluates runner-produced selector rejection only against the secret-bearing `privileged_merge` job's extracted `runs-on` expression.
