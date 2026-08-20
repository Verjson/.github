---
date: 2026-08-20
issue: 959
impact: patch
title: Stop the generated pr-gate caller persisting its job credential into PR-authored code
---

`scripts/gen-changelog-caller.sh pr-gate` emitted `actions/checkout` with no `persist-credentials: false`, so the job's `GITHUB_TOKEN` was written into `.git/config` and was still there when the very next step ran PR-authored `scripts/changelog-contract.test.sh` out of the same workspace. Nothing in that job fetches or pushes afterwards, so the generated checkout now sets `persist-credentials: false`, and every step it emits carries a `name:`.

The token is only `contents: read` and the default runner is ephemeral (#935), so the exposure was narrow — but it was a read-scoped token for a private repository handed to arbitrary pull-request code for no gain. The un-named steps were the second half of the report: adopters cannot hand-edit generated output, and a policy scanner that keys sections off the `- name:` marker read this job as having no checkout at all, which is how the missing control stayed invisible while the adopter's own trust-policy check reported "valid".

The other generated modes were audited for the same default. `release-node` emits three checkouts: two already set `persist-credentials: false`, and the third ("Check out the tree that will be released") legitimately keeps the credential because the later "Resolve restart-safe release state" step runs `git ls-remote` and `git fetch` against `origin` in the same job — it is left as-is. No other mode emits a checkout. `scripts/ci-gate/changelog-caller-contract.test.sh` now asserts that invariant across every workflow-emitting mode with that one exception named in the test, so a new mode cannot inherit the persisting default unnoticed.
