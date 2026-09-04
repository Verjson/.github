---
date: 2026-09-04
issue: 1244
impact: patch
title: Make compatibility sandbox failures actionable
---

Give compatibility consumers an isolated writable npm cache, report failed commands with
their exit status and a bounded output tail, and document the top-level bind-mount inode
constraint. Mask ambient npm cache and config paths and reject top-level checkout symlinks
that cannot remain workspace-confined, without weakening the credentialless read-only
sandbox boundary.
