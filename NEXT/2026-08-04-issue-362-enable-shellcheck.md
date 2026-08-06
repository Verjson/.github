---
date: 2026-08-04
issue: 362
title: Require ShellCheck on every actionlint route
---

Enable ShellCheck explicitly for Verjson-owned and external workflow linting now
that the governed self-hosted image supplies it. Adjudicate the current findings,
pin the required invocation and missing-tool failure in the reusable actionlint
contract tests, and record the policy amendment in ADR 0026.
