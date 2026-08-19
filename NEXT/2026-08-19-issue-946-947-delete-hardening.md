---
date: 2026-08-19
issue: 946
impact: patch
title: Harden the deferred arm-receipt deletion against credential leaks and write failures
---

Two non-blocking AI-review follow-ups on #945:

- Both callers' inline `gh api --method DELETE` on the consumed receipt artifact
  printed unsanitized stderr on failure, unlike every other API call in this path,
  which redacts an `authorization:` header before it can reach a log (#946). Both
  now redirect stderr and apply the same redaction.
- `verify-arm-receipt.sh`'s `printf` recording the artifact ID for deferred deletion
  ran under `set -e` with no failure guard, so a write failure (an unwritable
  `$ARM_RECEIPT_ARTIFACT_ID_FILE`) would have failed an otherwise-successful
  verification (#947). The write is now best-effort, matching the deletion it enables.

Refs #946, #947.
