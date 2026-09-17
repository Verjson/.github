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

**The review environment is read back, not inferred.** GitHub creates a
referenced environment on first use with no protection rules, so an adopter that
installs the caller without first provisioning `ai-review-app` gets a working
review lane and an unprotected environment, and every signal reports success
(ADR 0187). The audit reads the environment back and compares its deployment
branch policy against the contract with the same field-scoped comparator, so a
field GitHub adds to the environments schema is tolerated while an unexpected
value for an asserted field is still a finding.

It also requires the policy to admit the adopter's **own** default branch.
`custom_branch_policies: true` states that the policy is custom, not what it
admits: a policy mirrored field by field from this repository reads as
conformant while naming a branch the adopter does not use, which is the
appearance of confinement with none of its effect.

**Both classes of finding are reported together.** The audit runs daily; one
class at a time would make the fleet take as many scheduled days to become
visible as there are classes, which is the failure shape #1404 exists to remove.

The declared set is the full generated caller family — `ai-review-merge.yml`,
`ai-review-label-rearm.yml`, `ai-privileged-merge.yml`, `ai-promotion-retry.yml`
— so the first scheduled run will report adopters that are merely incomplete
alongside the four that are broken. That is the fleet state ADR 0187 predicted
from the pin skew, not a defect in the audit. Membership is asserted by path for
regular files only; the audit does not read or compare caller contents, so a
caller present at a stale contract SHA is out of scope here and remains ADR
0185's problem.
