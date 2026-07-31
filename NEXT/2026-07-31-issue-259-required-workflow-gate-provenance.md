---
date: 2026-07-31
issue: 259
title: Trust organization required-workflow runs as gate provenance
---

The privileged merge only recognised the gate when a repository ran
`ai-review-merge.yml` itself or called it as a reusable workflow. Verjson consumers
receive it through the organization ruleset `main-protection`, whose runs carry a
repository-scoped `workflow_id` and no `referenced_workflows`, so provenance never
became trusted and every privileged run exhausted its bounded wait with
`trusted gate/checks did not become green`. The dispatched continuation additionally
required its own `source_run_id` to be a `workflow_dispatch` run, which the
`pull_request`-triggered gate never is. Together these left consumer pull requests
OPEN/BLOCKED with a cancelled `privileged_merge` check and nothing running.

Required-workflow runs are now trusted, anchored on the organization ruleset naming the
trusted repository at `refs/heads/main` — read across every page, since a rule the first
page omits could otherwise launder an impostor, and re-checked immediately before merge
on a base branch asserted unchanged. The dispatched path validates its source run with
the same predicate plus an expected-head binding, and a pull request already merged at
the verified head settles as a terminal no-op instead of a red run. See
[ADR 0039](../docs/decisions/0039-required-workflow-gate-provenance/README.md); the
residual trust window is tracked in
[#261](https://github.com/Verjson/.github/issues/261).
