---
date: 2026-09-26
issue: 1617
impact: patch
title: Close the container-deployment generator's empty-config fail-open under jq 1.6
---

`scripts/gen-container-deployment.sh`'s `contract-test` mode generates a
deployment-config validator that relies on `jq -re` to reject a config
producing no violations output, with a comment explaining the intent:
"`-e` keeps an empty or input-less config a rejection: jq yields no result
at all for one." Under jq 1.6, that doesn't hold — `jq -re` against a truly
empty or whitespace-only file exits `0` regardless of `-e`, because the
filter never runs when there is no JSON value to run it against (`-e`
reports on the filter's *result*, not on whether it ran at all). That let an
empty or whitespace-only `container-deployment.json` silently pass, the
inversion the comment says `-e` was there to prevent.

This repo's own meta-test (`scripts/container-deployment-contract.test.sh`)
already encoded the correct expectation and was failing against it on
`main`. Fixed by checking for an empty or whitespace-only config in plain
bash (`[ -s "$config" ]` and `grep -q '[^[:space:]]'`) before jq ever sees
the file, so the check no longer depends on jq's version-specific `-e`
behavior for the zero-value-input case. No new test was needed; the existing
assertion now passes.

Sibling of #1612 (`validate_privileged_lane`'s equivalent fail-open in
`ai-privileged-merge.yml`, still open).
