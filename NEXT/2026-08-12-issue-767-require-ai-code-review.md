---
date: 2026-08-12
issue: 767
title: Require bounded AI review for code-changing pull requests
---

Require code, executable dependency, workflow, policy, prompt, and agent-instruction changes to receive one or two cumulative AI review passes while retaining no-model validation for generated lockfile-only and non-agent documentation changes.

Each provider invocation now reserves visible pass `1/2` or `2/2` evidence as an exact-head dedicated-App review before execution, so the shared Actions identity cannot forge the counter, failed and inconclusive attempts consume the allowance, and a third call cannot mint autonomous merge authority. Fallback admission uses the first reservation's output directly, avoiding an eventually consistent read-after-write. ADR 0098 records the sensitive merge-gate decision.
