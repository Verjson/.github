---
date: 2026-08-16
issue: 862
impact: patch
title: Diagnose release tests that hardcode package versions
---

Generated Node release callers now warn that verification runs after the dispatched package version is stamped and report that version when the suite fails, pointing adopters to version assertions that must read `package.json` dynamically.

The generator-owned contract tests lock the warning and failure diagnostic without heuristically scanning consumer test files.
