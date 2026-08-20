---
date: 2026-08-20
issue: 971
impact: patch
title: Verify the release-node credential exemption structurally, not by name alone
---

The #959 checkout-credential audit exempted `release-node`'s "Check out the
tree that will be released" step by name only, trusting that a step named
"Resolve restart-safe release state" still consumed the credential. Renaming
or defanging that consuming step would have silently kept the exemption
alive. The audit now looks up the named consumer step and requires its `run`
body to still contain the git remote operations (`git ls-remote`, `git
fetch`) the exemption is justified by; either drifting re-flags the checkout.
