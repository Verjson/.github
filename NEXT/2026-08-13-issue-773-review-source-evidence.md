---
date: 2026-08-13
issue: 773
title: Bind blocking AI findings to exact-head source
---

Require every blocking AI review finding to cite exactly one source line and carry evidence that deterministically matches that line at the receipt-bound reviewed head before the verdict can be published or authorize promotion.

Mismatched evidence consumes the reserved pass but remains unusable, so only the existing permitted fallback can run and the cumulative two-pass ceiling stays fail-closed. ADR 0100 records the trust boundary and its semantic limits.

Preflight now also retries the required paginated PR-files read four times without delay when GitHub temporarily cannot compute a diff. Persistent input unavailability is classified as infrastructure unavailable and fails closed before any model pass is reserved or counted.

Maintainer-authorized `re-review` labels now bind one explicit diagnostic pass into the arm receipt, publish a distinct App reservation marker, count toward telemetry, suppress automatic fallback, and reject any second reservation for the same authorization check without weakening the normal two-pass ceiling. When GitHub creates no run for a label event, rerunning an existing exact-head arm safely resolves and authorizes the current label actor, revalidates current PR state, issues a fresh receipt, and consumes the label after dispatch; this recovery does not claim to repair GitHub event delivery.
