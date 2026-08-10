---
date: 2026-08-10
issue: 702
title: Keep authorization App approvals within their permission envelope
---

Include read-only repository contents in the narrowly minted authorization App token and resolve the pull request head through REST using that App token, so exact-head approval and check completion stay within its least-privilege permission envelope.

The contract test rejects reintroducing the GraphQL-backed `gh pr view` lookup or routing the PR-head read through the restricted workflow token, and now stops immediately if its semantic validator fails. The workflow token remains isolated to immutable arm-receipt verification.
