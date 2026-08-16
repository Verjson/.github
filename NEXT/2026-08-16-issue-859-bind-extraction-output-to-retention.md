---
date: 2026-08-16
issue: 859
impact: patch
title: Bind extraction diagnostics to retained artifacts
---

Expose DeepSeek extraction diagnostics to workflow consumers only after their bounded, redacted artifact has been written successfully.

This prevents replay preparation from claiming unavailable evidence while preserving the diagnostic path's non-authorizing behavior.
