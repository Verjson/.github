---
date: 2026-09-17
issue: 1401
title: record that the review environment is provisioned before the caller that names it
impact: patch
---

Adds ADR 0187. The generated AI review caller passes a required `ai_review_environment`
input that resolves in the adopter's repository, and GitHub creates a referenced
environment on first use with no protection rules. Installing the caller without creating
`ai-review-app` first therefore yields a working review lane and an unprotected
environment, with every signal reporting success — trading a loud failure for a silent one.

The decision fixes the ordering and requires the branch policy to be read back from the API
rather than inferred from a green run, since a green run is exactly what the unprotected
case produces.

Recorded while remediating #1401, where four repositories carrying
`verjson-core-checks=enforced` had no review caller at all and every pull request in them
failed the required arm. First applied in `Verjson/verjson-ci#189`.

The ADR also records that an environment provisioned this way is protected but empty: the
secret policy names each adopter's `ai-review-app` as the intended custodian of
`AI_REVIEW_APP_PRIVATE_KEY`, and these environments currently resolve the organization
residue copy instead. That copy has drifted from its declared `selected` target to `all`,
which `scripts/org-secret-scope-audit.py` already detects and exits 1 on.
