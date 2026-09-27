---
date: 2026-09-23
id: 20260923T000002Z
title: Repin the authn required caller to the hardened protected workflow
impact: patch
---

The generated authn required caller now references the immutable commit that
contains the declaration-only lane hardening and prerelease authorization fix.
