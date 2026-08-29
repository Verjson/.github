---
date: 2026-08-29
issue: 1177
impact: minor
title: Protect the cli-projects package-surface gate
---

Add the organization-owned, exact-repository cli-projects package-surface required
workflow and a fail-closed transactional rollout plan. The protected verifier parses
shipped workflow YAML semantically, requires immutable action and container references,
checks the public package surface, and exercises the candidate archive without secrets
or persisted credentials on an ephemeral hosted runner. Adversarial controls reject
pull-request check-name spoofing, mutable references, duplicate triggers, weakened
verification steps, ambiguous provider identity, preimage drift, and partial activation.
Applied-remotely/client-failed mutations reconcile and roll back to the reviewed
non-enforcing image; retries resume only an exact uniquely identified staged rule.

The live organization and repository rulesets remain unchanged until the protected
bytes are merged, independently reviewed, and a fresh exact-head required-workflow
canary supplies the held activation receipt.
