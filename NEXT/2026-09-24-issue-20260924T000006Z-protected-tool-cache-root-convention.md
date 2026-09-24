---
date: 2026-09-24
id: 20260924T000006Z
title: Accept the hosted setup-node cache root convention
impact: patch
---

Allow the exact root-owned `0777` `/opt/hostedtoolcache` directory used by
GitHub-hosted runners while retaining strict ownership and mode checks for every
tool prefix, executable, and descendant mounted into the protected sandbox.
