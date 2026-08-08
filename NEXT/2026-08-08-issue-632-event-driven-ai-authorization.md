---
date: 2026-08-08
issue: 632
title: Delegate AI-authorized merges to GitHub native auto-merge
---

Replace runner-held CI polling with an exact-head AI authorization check and GitHub native auto-merge, deduplicating automatic model review to once per PR head.

Trusted base-branch callers use a dedicated GitHub App and immutable arm-run receipt to create the required check, fail closed for stale or fork heads, and dispatch secret-backed review without executing pull-request code. Clearing a hold never automatically buys another same-head review: failed results require an explicit `re-review`, while pending results produce wait or administrator-recovery guidance. ADR 0079 keeps ruleset migration unavailable until provisioning blocker #641 is fulfilled and the exact App- and receipt-bound check is proven on a test head.
