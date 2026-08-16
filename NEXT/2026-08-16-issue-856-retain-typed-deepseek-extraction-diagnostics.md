---
date: 2026-08-16
issue: 856
impact: patch
title: Retain typed DeepSeek extraction diagnostics
---

Classify completed DeepSeek response-extraction failures and retain a bounded, non-content diagnostic artifact so deterministic advisories name the cause without granting review authority.

Raw provider verdicts, reasoning, usage values, exception details, prompts, diffs, metadata, and secrets remain excluded. The exact-head two-pass ceiling is unchanged; see ADR 0107.
