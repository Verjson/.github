---
date: 2026-08-07
issue: 535
title: Make generated Node publication restart-safe
---

Generated Node release callers can now recover when npm accepts a package but GitHub Release creation fails, without overwriting immutable packages or tags.

Reruns pack the attested snapshot and skip package publication only after authenticated registry evidence matches the exact name, version, and sha512 integrity. Missing, spoofed, mismatched, or unavailable evidence fails closed before release notes are reconciled.
