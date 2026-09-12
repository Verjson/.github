---
date: 2026-09-12
id: 20260912T230000Z
impact: patch
title: stamp selected packages before release builds
summary: node-release now stamps every selected package with the dispatched version before any selected package build, so generated component callers cannot publish stale dist output.
---

Stamp every selected package before building and publishing its release artifact.
