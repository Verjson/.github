---
date: 2026-08-08
id: 20260808T184150Z
title: Pin the authorization App token action to v3
---

Update both trusted authorization workflows to the immutable v3 release of `actions/create-github-app-token`. Strengthen the security contract to require the official action, a full lowercase 40-hex commit SHA, and the same pin at both token-minting sites.
