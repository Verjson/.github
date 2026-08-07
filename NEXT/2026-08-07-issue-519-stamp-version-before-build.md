---
date: 2026-08-07
issue: 519
title: Stamp the dispatched npm version before release builds
---

Generated Node release callers now apply the dispatched package version before both verification and publish-time builds, preventing artifacts from embedding the stale branch version.

The metadata-only stamp stays uncommitted, disables lifecycle scripts, and is repeated from the explicit dispatch input on both sides of the changelog-only snapshot. Generated contract coverage rejects reordered or missing stamps.
