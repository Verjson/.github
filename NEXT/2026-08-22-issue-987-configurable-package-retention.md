---
date: 2026-08-22
issue: 987
impact: minor
title: Make package retention count configurable and require rename-deprecation stubs
---
Package retention's `keep` count is now a parameter (default 3, unchanged) instead of a hardcoded literal — `scripts/package_retention.py` exposes `--keep` on its CLI, and `node-release.yml`/`container-release.yml` source it from the org variable `VERJSON_PACKAGE_RETENTION_KEEP`, falling back to 3. No org variable is set by this change, so retention still keeps exactly the newest three stable versions everywhere.

`node-release.yml` also gains an optional `deprecates` input: a JSON array of `{"name","message"}` old scoped-package basenames that get `npm deprecate`d immediately after a successful publish. A repository renaming a package now has a supported way to leave a forwarding pointer at the old name in the same release that stops publishing it, instead of the old name silently aging out — the failure mode that turned `@verjson/uploads` into a bare 404 when it became `@verjson/object-storage`.

ADR 0115 records both decisions and the one explicitly deferred: a pre-delete check that a version is not still pinned by a known consumer's lockfile is out of scope for this repository, since no cross-repository consumer/lockfile inventory exists to check against. The "stop deleting vs. keep a longer window" retention-count policy question from #987 also remains open for a human with GitHub Packages billing visibility — this change only removes the hardcoded blocker to answering it via config.
