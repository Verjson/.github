---
date: 2026-08-01
issue: 270
title: Narrow the public repository surface and require approval for every external fork PR
---

Organization-configuration change, made in response to a finding recorded in
[ADR 0041](../docs/decisions/0041-shared-admission-hosted-and-self-hosted/README.md).

Accepting a shared runner pool for public and private repositories makes per-repository
fork-PR approval a load-bearing control, because the org-side admission layer no longer
denies public repositories and `ai-review-merge.yml` places caller-controlled
`inputs.runner_labels` first in the `runs-on` chain, read from the PR head. When measured
there were four public repositories, three of them at `first_time_contributors` — so a
contributor approved once could run fork-head workflow content on the six hosts carrying
the `gate` label.

Two changes narrow that surface:

- `Verjson/verjson-browser-agent` and `Verjson/agents` are now **private**. Neither had
  forks, stars, pages, packages, or more than two minutes of CI, so no fork detached and
  no billing changed materially. Public repositories go from four to two.
- Fork-PR approval is `all_external_contributors` on every repository where the setting
  applies, so a maintainer must approve *every* fork-PR workflow run from a
  non-collaborator rather than only the first.

`Verjson/.github` stays public deliberately — other organizations consume it.

The residual risk is unchanged in kind and is recorded in ADR 0041: an approved fork PR
still executes on the `gate` hosts, so approving one on a public repository is a
security-relevant action rather than a routine courtesy.
