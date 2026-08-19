---
date: 2026-08-19
issue: 943
impact: patch
title: Delete the arm receipt at the caller's true terminal success, not at verification
---

#942 deleted the arm receipt artifact inside `verify-arm-receipt.sh`, immediately on
successful verification -- before the rest of the calling step's own work (completing
the check run, or the terminal merge) had actually run. If that later work failed for
an unrelated transient reason and the step were retried, the retry's own
re-verification would find the receipt already gone, with no way to recover short of
restarting the whole arm cycle.

`verify-arm-receipt.sh` no longer deletes anything itself. A caller that sets
`ARM_RECEIPT_ARTIFACT_ID_FILE` gets the verified artifact ID written to that path on
success and deletes it independently, once it has confirmed its own true terminal
success: `complete-authorization` after its check-run PATCH to `completed` succeeds
(any conclusion), `privileged_merge` after GitHub confirms the PR is actually merged.
See ADR 0110's 2026-08-19 amendment.

Refs #943.
