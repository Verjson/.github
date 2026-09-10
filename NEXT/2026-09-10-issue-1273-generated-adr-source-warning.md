---
date: 2026-09-10
issue: 1273
impact: patch
title: Identify generated ADR index copies and remove reported shell diagnostics
---

Add the generated-file warning and regeneration command to the canonical ADR index source copied into adopters. Brace the emitted contract-ref regex variable to avoid ShellCheck SC1087, and express missing-marker rejection as an explicit conditional without SC2015. Both single-marker failures remain non-mutating; generated artifacts stay pinned to exact canonical bytes.
