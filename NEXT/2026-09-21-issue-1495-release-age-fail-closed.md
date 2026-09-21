---
date: 2026-09-21
issue: 1495
impact: patch
title: Defer AI review when the Renovate release-age status cannot be read
---

Treat an unreadable `renovate/stability-days` status as unverified and defer the review lane instead of silently treating the gate as clear. The extracted workflow test covers the transient API failure path.
