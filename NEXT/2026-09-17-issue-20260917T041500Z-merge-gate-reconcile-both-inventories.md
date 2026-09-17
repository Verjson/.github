---
date: 2026-09-17
id: 20260917T041500Z
title: Reconcile both merge-gate inventories and require the endpoint's attestation
impact: patch
---

The independent review of the previous merge-gate hardening found the page-walk
reconciliation had been applied to only one of the two inventory endpoints.
Commit statuses are the half Gate C reads a stranded `failure` from, so a short
walk there hides precisely what that gate exists to see. Both fetches now share
one `reconcile_pages` helper.

The helper no longer defaults the claimed count to the observed one. That
default made the guard vacuous exactly where it mattered: a body carrying no
`total_count` — or no body at all — reconciled zero against zero, and the gate
went on to reason over an inventory in which no check could be seen. Both
endpoints were confirmed against a live commit to always send the field,
including the empty case, which reports `total_count: 0`.

Three smaller review findings land with it: the unbound-context substitution
carried no `|| fault`, which this script's own header forbids, so a `jq` failure
silently dropped the ADR 0024 degradation warning; a `2>/dev/null` was bound to
`[` rather than to the substitution it was meant to cover, reporting an
unevaluable required set as an ungoverned ref; and a comment claimed a name trim
nothing performs, where the absence of trimming is deliberate and fails closed.

Part of #1364
