---
date: 2026-09-24
id: 20260924T000006Z
title: Accept the hosted setup-node cache root convention
impact: patch
---

Allow only the exact `0777` `/opt/hostedtoolcache` directory with the known
GitHub-hosted runner ownership (`uid 0 or 1001`, `gid 0`). Retain strict
ownership and mode checks for every tool prefix, executable, and descendant
mounted into the protected sandbox.
