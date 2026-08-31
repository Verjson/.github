---
date: 2026-08-31
issue: 1210
impact: patch
title: Stop reading a second reusable-workflow caller as a job-name violation
---

- Scope the core-checks audit's stack-caller check to the job that actually publishes the required contexts, so a repository that calls the same reusable workflow again under another job name is no longer reported nonconformant.

`caller_job_for` prints one line per job referencing the stack workflow, and the
caller compared that whole multi-line result for equality with the single
expected name. Any repository running a Node floor matrix or a downstream
compatibility lane alongside `ci` therefore failed with
`caller-job-name expected=ci actual=ci\nci-node-floor`. Those extra callers
publish their own differently-prefixed contexts, satisfy no rule, and are
outside this contract.

The audit now requires exactly one job named `ci`, keeps the existing
`caller-job-name` diagnostic for the case where no caller carries the canonical
name, and adds `stack-caller-duplicate` for two jobs that both do — one required
context published by two check runs is ambiguous even though each name is right.
The `workflow-path-filter` check is scoped to the file holding the canonical
caller for the same reason.

Live re-audit of the five affected repositories (`verjson-ai-gguf`,
`verjson-customer-lifecycle`, `verjson-eslint-config`, `verjson-observability`,
`verjson-temporal-kit`) reports all five conformant with no consumer change.
Unblocks that part of #731; the remaining six failures are real consumer drift.
