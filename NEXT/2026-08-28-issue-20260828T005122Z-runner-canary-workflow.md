---
date: 2026-08-28
id: 20260828T005122Z
impact: minor
title: Publish the immutable exact-runner canary
---
Publish the canonical database-backed runner canary at a versioned immutable ref, binding promotion to one runner transaction and the reviewed CLI workflow bytes.

The canary completes [#629](https://github.com/Verjson/.github/issues/629)'s exact-runner admission path. It verifies the transaction through its unique runner label, database and sibling Docker connectivity, a representative image build, PowerShell, and post-job disk and inode capacity before emitting the digest-bound promotion receipt. Exact disposable-resource absence is proven after cleanup; survivors, inventory failures, and cleanup-phase signals fail closed without leaving promotion evidence. ADR 0150 defines the `runner-canary-vX.Y.Z` publication and rollback contract.
