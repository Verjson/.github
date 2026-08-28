---
date: 2026-08-28
issue: 1122
impact: patch
title: Clarify failed provider-gate recovery status
---

Report failed or cancelled AI review gates as having reached or ambiguously approached the provider boundary, making clear that their retained receipt cannot use zero-provider recovery.

This preserves the fail-closed behavior from ADR 0145 while replacing a generic authorization failure with the causal recovery status.
