---
date: 2026-08-26
issue: 1109
impact: minor
title: Populate secretless public runtime caches from verified lock blobs
---

Add an opt-in canonical Node CI input that copies only complete, SHA-512-verified
public npm registry blobs from the credentialless install cache into the exact
job-scoped runtime cache. Lock-derived count and byte bounds, exact destination
binding, and missing, corrupt, and internal-package controls keep private
content, cache indexes, request metadata, symlinks, and credentials outside the
handoff.
