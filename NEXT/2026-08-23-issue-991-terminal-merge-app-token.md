---
date: 2026-08-23
issue: 991
impact: patch
title: Bind terminal merge to a repository-scoped App token
---

Replace the terminal merge PAT with a short-lived GitHub App token restricted to the exact authorized repository and only contents-write and pull-requests-write. Generated callers now pass only the merge App client ID and private key. See ADR 0120.

All authorization and post-merge verification remain on a read-only repository token. The merge token is minted only after authorization and is delivered only to the exact-head `gh pr merge --admin --squash` operation; missing, numeric, wrongly installed, widened, or unmintable App credentials fail closed.

The rollout is verified only when this controlled documentation-only canary reaches the
terminal continuation at the immutable App-token contract SHA and GitHub records App ID
4693283 as the actor that admin-squash merges its exact reviewed head.
