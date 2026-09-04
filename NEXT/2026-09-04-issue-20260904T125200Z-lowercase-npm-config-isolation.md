---
date: 2026-09-04
id: 20260904T125200Z
impact: patch
title: Isolate lowercase npm configuration paths
---

Mask lowercase npm user and global config paths and redirect every config-variable case variant to sandbox-owned empty npmrc mounts so compatibility code cannot recover ambient registry credentials through npm's lowercase environment aliases.
