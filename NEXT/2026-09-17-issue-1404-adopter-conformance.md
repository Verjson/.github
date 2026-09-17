---
date: 2026-09-17
issue: 1404
title: The authorization arm audit reaches adopter conformance
impact: minor
---

`scripts/ai-review-required-workflow-audit.py` now audits the adopters the arm
governs, not only the organization objects that arm them. Making the audit
runnable and scheduling it (#1406, #1413) fixed the first three items of #1404;
this is the fourth, and the one `Verjson/.github#1401` needs.

**The generated caller set is asserted as a set.** Enrollment is granted by the
`verjson-core-checks=enforced` property and admission requires a
repository-local caller that property says nothing about, so the two diverge
silently until an adopter's next pull request fails the required arm. The audit
now reports every armed repository missing any member of the caller family
declared in `config/ai-review-required-workflow-rollout.json`. Asserting the
set rather than any member is the point ADR 0187 records: `verjson-agents`
carries `ai-privileged-merge.yml` and `ai-promotion-retry.yml` without the
`ai-review-merge.yml` that `gate-rearm.yml` hard-requires, so a
presence-of-any-member check answers yes while the arm cannot run at all.

The adopter's workflow listing is adopter-controlled text. It is used only to
test membership against the paths the reviewed contract declares — never
parsed, interpolated, or executed.

**A per-adopter absence is a finding, not a dead audit.** `gh_pages` gained an
opt-in `allow_missing` that returns no pages for an HTTP 404 and still raises
for every other status, so an expired credential cannot be reported as fleet-wide
non-adoption, and one unadopted repository cannot abort the sweep before it
reaches the rest — which is the failure mode #1404 exists to remove.
