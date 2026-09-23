---
date: 2026-09-23
issue: 1575
impact: patch
title: Resolve consumer type-surface baselines from protected declarations
---

The protected Node CI contract now reads an exact consumer baseline declaration from the authenticated pull-request base commit, verifies its package and script against protected policy, resolves the exact released artifact, and carries the declaration and artifact binding in the credentialless evidence receipt.

The declaration is intentionally the only consumer-owned selection surface; it contains no Git SHA and cannot affect the pull request that proposes it. Authn and authz adoption follows the generated protected caller instructions.
