---
date: 2026-08-10
issue: 731
title: Stage the generated changelog contract as a required Node check
---

Declare `changelog-contract` as a required Node context and gate its organization rollout on exact property-selected heads, canonical generated-artifact byte identity, merged rollout code, full preimage stability, explicit human acknowledgement, and exact post-write verification.

ADR 0092 keeps fragment validation separate from generated workflow, renderer, contract-test, and release-caller pin conformance, and adds a protected exact-preimage recovery artifact with executable rollback. The live ruleset remains unchanged while the selected consumer fleet and #728's universal gate are nonconformant.

The audit accepts generator pins only when they are reachable from the canonical repository's current default branch, and executes the verified merged generator without inherited credentials.

**2026-08-22 update:** the staged rollout's own read-only audit (`RCA_APPLY=false
bash scripts/required-checks-rollout.sh`) reported all 22 property-selected
node-stack repositories nonconformant, including a sample generated fresh from this
repository's own current `gen-changelog-caller.sh pr-gate` output — proof the
audit's classifier (`scripts/required-checks-workflow.py`), not consumer drift, was
the bug. It still validated the `changelog-contract` job's original 2-step shape
(checkout + run), stale since generator changes #638 (job-scoped tool cache) and
#959 (`persist-credentials: false` on checkout) moved the canonical output to 3
steps. Fixed the classifier to accept the current 3-step shape. Real remaining
drift persists in several consumer repositories still pinned to a pre-#959 contract
SHA; that is cross-repository work outside this repository's ownership boundary.
The ruleset mutation itself stays behind the script's own explicit
`human_gate_required` acknowledgement.

**2026-08-24 update:** stop the staged generated-changelog ruleset audit from
requiring the obsolete `gate` authorization context while preserving fail-closed
`changelog-contract` validation. ADR 0128 aligns #731 with the dedicated
authorization-arm ruleset introduced by ADR 0094. The live ruleset remains
unchanged and activation remains blocked until all selected consumers conform.
