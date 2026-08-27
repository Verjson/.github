---
date: 2026-08-27
id: 20260827T034000Z
impact: patch
title: Repair canonical container release preflight
---

Capture the artifact ID and digest together before immutable release preflight reads the
digest group, require Python 3 for all release validators, and enforce both bindings in
the canonical release contract.
