---
date: 2026-08-26
issue: 1110
impact: patch
title: Reserve DeepSeek review completions for JSON verdicts
---

Disable thinking for tool-free DeepSeek JSON reviews so the bounded completion is
reserved for the required verdict, and fail closed if a provider emits unexpected
reasoning. See ADR 0142.

Streaming, usage and cost evidence, exact-head admission, two-pass limits, redacted
diagnostics, and typed empty-content failures remain unchanged.
