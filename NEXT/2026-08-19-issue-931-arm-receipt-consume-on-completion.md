---
date: 2026-08-19
issue: 931
impact: patch
title: Delete the arm receipt artifact once its last required read succeeds
---

`gate-rearm.yml`'s immutable arm receipt uploaded with a 90-day retention and no
delete-on-consumption, so it grew unbounded with organization PR volume and
exhausted the org-wide Actions artifact storage quota, blocking every
authorization arm org-wide (observed failing `verjson-browser-agent#46` and
`verjson-cloud-storage#92` at the upload step itself).

`verify-arm-receipt.sh` now deletes the receipt artifact when its caller sets
`CONSUME_RECEIPT=true`, as a best-effort step after successful verification —
never a security control, and never able to fail an otherwise-valid
authorization. `ai-review-merge.yml`'s `complete-authorization` job sets it
whenever the resolved authority is not `ai-merge` (its own read is the
receipt's last required one on that path); `ai-privileged-merge.yml`'s
`privileged_merge` job always sets it (it only runs under `ai-merge` authority,
after `complete-authorization` has deliberately deferred consumption to it).
An unconsumed receipt still falls back to the original 90-day retention for a
genuinely held PR.

`complete-authorization`'s workflow-token permission moves from `actions: read`
to `actions: write` to perform the delete.

Refs #931.
