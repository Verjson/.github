---
date: 2026-08-14
issue: 699
title: Remove the repository Renovate policy override
---

Remove the repository-level Renovate configuration so organization policy remains the single dependency-update control plane, and add conformance coverage that rejects supported local override forms.

This is the managed `Verjson/.github` slice of #699. The broader organization policy remains blocked by `Verjson/renovate-config#12`.
