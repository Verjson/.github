---
date: 2026-10-02
id: 20261002T143132Z
refs: 1667
impact: minor
title: Verify OCI candidate registry destinations
---

Trusted container publication can mirror complete multi-platform OCI candidates
from canonical GHCR to a reviewed GAR destination. Candidate manifests record
read-back digests and per-destination expiry; promotion fails closed after the
canonical candidate expires. Retention values must be integers; booleans are
rejected. Mirror receipts carry the validated variant for workflow selection;
it is removed before the strict release-manifest schema is applied.
