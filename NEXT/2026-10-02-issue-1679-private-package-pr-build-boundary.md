---
date: 2026-10-02
issue: 1679
impact: patch
title: Keep private package contents out of pull-request builds
---

Container-candidate pull requests no longer acquire or mount private Node packages; when `privateNodePackages` is configured, the workflow clearly skips PR-controlled Docker builds and leaves private-package acquisition to trusted default-branch publication.

The read-only caller no longer receives `packages: read` or `NODE_AUTH_TOKEN`. ADR 0214 records the boundary and its narrow supersession of the earlier PR acquisition design.

Private dependency acquisition in the publish workflow is also limited to trusted default-branch publication events and runs only after preparation succeeds. Read-only pull-request jobs ignore caller-selected runner labels.

Private dependency archives transferred between workflow jobs are authenticated ciphertext in Actions caches. Only jobs in the same workflow run receive the decryption key, so a pull request restoring a default-branch cache cannot read the package contents.
