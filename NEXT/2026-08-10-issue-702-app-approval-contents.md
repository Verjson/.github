---
date: 2026-08-10
issue: 702
title: Keep authorization App approvals within their permission envelope
---

Include read-only repository contents in the narrowly minted authorization App token and resolve the pull request head through REST so exact-head approval and check completion stay within the App's least-privilege permission envelope.

The contract test rejects reintroducing the GraphQL-backed `gh pr view` lookup in this privileged path.
