---
date: 2026-08-16
issue: 856
impact: patch
title: Retain typed DeepSeek extraction diagnostics
---

Classify completed DeepSeek response-extraction failures and retain bounded, pass-specific, non-content diagnostic artifacts so deterministic advisories name each exact cause without granting review authority.

Raw provider verdicts, reasoning, usage values, exception details, prompts, diffs, metadata, and secrets remain excluded. The exact-head two-pass ceiling is unchanged; see ADR 0107.
