---
date: 2026-08-17
issue: 886
title: Import verified pnpm cache blobs as tarballs
impact: patch
---

Secretless pnpm CI now copies verified npm cache blobs to temporary `.tgz` package specs before importing them into the pnpm store, preventing runtime rejection of extensionless content-addressed cache paths.
