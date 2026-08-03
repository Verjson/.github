---
date: 2026-08-03
issue: 372
title: Update release tooling past the new undici advisories
---

Refresh the release-tooling lockfile to `undici` 6.28.0/7.29.0 and npm 11.19.0.
This removes the newly published high-severity response-cache advisory without
adding an audit exception. npm's bundled `undici` remains on 6.27.0 with only
the moderate advisory, below the high/critical release gate.
