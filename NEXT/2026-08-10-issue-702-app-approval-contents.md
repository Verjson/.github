---
date: 2026-08-10
issue: 702
title: Keep authorization App approvals within their permission envelope
---

Include read-only repository contents in the narrowly minted authorization App token and resolve the pull request head through REST using the explicitly read-scoped workflow token, so the App token remains dedicated to approval and check mutations.

The contract test rejects reintroducing the GraphQL-backed `gh pr view` lookup or routing the PR-head read through the App token, and stops immediately if its semantic validator fails. Phase-specific diagnostics distinguish head-read rejection from later App mutation failures.
