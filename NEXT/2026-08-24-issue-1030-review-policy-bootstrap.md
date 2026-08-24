---
date: 2026-08-24
issue: 1030
impact: patch
title: Restore review-policy bootstrap for the inconsistent historical caller
---

The trusted authorization arm now recognizes the byte-exact generated caller at the
historically inconsistent contract revision and projects only safe, human-authority
Anthropic policy into its legacy envelope. All other callers retain the current strict
schema, and malformed or widened recovery attempts fail before review dispatch.
