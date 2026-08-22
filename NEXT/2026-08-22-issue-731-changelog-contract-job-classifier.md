---
date: 2026-08-22
issue: 731
title: "fix(ci-gate): required-checks-workflow.py accepted only the pre-#638/#959 2-step changelog-contract job"
---

`scripts/required-checks-workflow.py`'s `changelog_contract_state()` still validated the
generated `changelog-contract` job against its original 2-step shape (checkout + run).
Two generator changes since — #638 (a job-scoped tool-cache step) and #959
(`persist-credentials: false` on the checkout step) — moved the canonical output to 3
steps with a nested `with:` block, so the classifier rejected every currently-correct
consumer as `invalid`. Read live for issue #731's staged `core-checks-node` ruleset
rollout: 22/22 node-stack repositories reported nonconformant, including a freshly
regenerated sample from this repository's own current generator output.

Fixed `changelog_contract_state()` to validate the current 3-step shape, including the
checkout step's nested `persist-credentials: false`, and extended `step_mappings()` to
flatten a nested step-level `with:` mapping instead of discarding it. Updated the stale
2-step fixture in `required-checks-audit.test.sh` and its checkout-escape sed injections
(which now target the existing `with:` block instead of adding a conflicting second one).

Re-running the live read-only audit after the fix shows the classifier bug is resolved
(repos on the current contract pin, e.g. `verjson-cli`, now read `valid`), but it also
surfaces genuine remaining drift: several node-stack repos are still pinned to a contract
SHA that predates #959 and need to regenerate `changelog-contract.yml`. That is
cross-repository consumer work outside this repository's ownership boundary and is
tracked as the remaining scope on #731.
