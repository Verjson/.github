---
date: 2026-08-14
issue: 629
title: Add the protected sequential runner deployment contract
---

Add an immutable generated deployment contract that retains pre-mutation authority,
proves an ordinary canary, and rolls an existing runner fleet sequentially behind the
consumer's protected production environment.

The reusable workflow, controller, preflight, receipt schema, adversarial tests, and
runbook enforce signer/source/contract pins, bounded capacity and time policy,
canonical manifest bytes, strict version 3 receipts, exact-plan dry-run evidence,
authority-checked append-only resume, truthful verified-or-unknown post-update state,
manifest/index-digest-bound unknown-state reconciliation, durable canary-observation progress,
independently approved rollback, least privilege, and no capacity-creating or
spend-increasing operations. Live
`Verjson/verjson-github-runner` adoption remains a separate post-merge handoff.
The final upstream admission integration uses the exact SHA-256 identity of the
canonical `release-manifest.json` asset throughout the workflow, controller, and
receipts; legacy registry-qualified manifest references fail before evidence
collection or fleet mutation. The deployment workflow acquires its CLI from the
immutable contract checkout with the exact npm lockfile, SHA-512 integrity
enforcement, read-only package authority, and disabled lifecycle scripts before any
evidence collection or fleet mutation.
