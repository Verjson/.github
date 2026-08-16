---
date: 2026-08-16
issue: 835
impact: patch
title: Align changelog generation and enforcement on the canonical check
---

Make every changelog caller generator publish `generated-artifacts / validate`, reject retired caller shapes in generated contract tests, and align the live organization ruleset with that canonical context.

This restores the invariant recorded in ADR 0075 while retaining `workflow` as a compatibility command for existing automation.
