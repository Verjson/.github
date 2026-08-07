---
date: 2026-08-07
issue: 390
title: Add component-scoped changelog releases
---

Allow multi-package repositories to scope fragments to explicit component streams while keeping unscoped rendering and release as the safe backward-compatible default.

ADR 0066 defines validation, selection, rendering, pull-request, and release invariants so scoped notes cannot silently leak into another immutable snapshot.
