---
date: 2026-09-17
id: 20260917T033000Z
title: Close the fail-open gaps the merge gate's hardening claim outran
impact: patch
---

Re-reviewing `scripts/assert-mergeable-head.sh` found four ways it could still
answer a question it had not actually asked.

The environment-override regression guard was vacuous. It exported the *sibling*
script's variable names, which this gate never reads, so a build in which Gate B
really was overridable would have passed it. The test now names this script's own
constants and is mutation-tested: restoring the override makes the suite fail.

Gate A's provenance half is conditional on the ruleset binding a context to an
App, and it degraded silently where no binding exists. That is not hypothetical —
this repository's own `main` ruleset declares `shell-tests` with
`integration_id: null`, so the binding never engages here at all, and matching on
display name alone is exactly the ADR 0024 class the gate exists to close. It now
warns and names every unbound context. It warns rather than refuses because
refusing would reject rulesets that are currently correct, including this hub's.

Legacy commit statuses were read unpaginated, against GitHub's 30-per-page
default, so a `failure` stranded on page two was invisible to Gate C — whose
whole job is to see it. Check runs now also reconcile the endpoint's
`total_count` against what the page walk actually collected rather than trusting
the walk, and a short inventory is a fault. That reconciliation shipped without a
test; the test is added here and mutation-checked, because accepting the claimed
count silently returns `true` on a head the gate never fully read.

Gate B's deferral pattern accepted only a space-separated prefix, so the
conventional `continuous-integration/deferred-ci` commit-status form and the
`deferred-ci / verify` sub-step form both escaped it. Both now block, and the
negative case distinguishes an anchored pattern from a sloppy substring match.

The ADR's provenance-override claims are narrowed to what the implementation
supports, and its live-endpoint evidence now records which context it was
verified against as unbound.

Part of #1364
