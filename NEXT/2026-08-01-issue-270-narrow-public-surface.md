---
date: 2026-08-01
issue: 270
title: Accept shared runner admission by decision, and narrow the public repository surface
---

## The admission discrepancy is resolved, in favour of the live state

The entry for #256 recorded that runner group 4 admits public repositories while ADR 0028
decision 4 forbids it, and left that open as a finding: ADR 0028's admission boundary was
**not in force**, with no record of when it lapsed.

[ADR 0041](../docs/decisions/0041-shared-admission-hosted-and-self-hosted/README.md) closes
it deliberately, and the other way round from what that entry implied. GitHub-hosted and
DigitalOcean self-hosted both serve public and private repositories for the foreseeable
future, and **ADR 0028 decision 4 is superseded**. The wider admission is now a decision,
not a drift.

The ADR also records what best practice *would* be — ephemeral hosts for untrusted code,
narrow admission, a merge gate that does not share hosts with pull-request content — as an
explicit North Star, with the accepted risks stated rather than softened, so the deviation
stays a decision instead of decaying into an accident. #204 stays open as the hook for that
target, not as a defect. ADR 0028 decisions 1 and 6 are recorded there as *already* lapsed;
decision 6 is tracked in #281.

The standing constraint that keeps it reversible: **capacity and provider changes are
variable changes.** New runners, more hosted compute, or a new provider is an organization
variable edit — never a `runs-on:` edit, and never a hardcoded pool, label, or runner-group
name. That constraint governs new routing; the inline `runs-on` long tail (#203) must still
be swept before any provider move.

## The organization changes that followed

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
- The **organization default** for the same setting was raised to
  `all_external_contributors` as well. Setting it per repository alone left the next public
  repository inheriting `first_time_contributors` silently, which defaults a load-bearing
  control open for anything created from here on.

`Verjson/.github` stays public deliberately — other organizations consume it.

The residual risk is unchanged in kind and is recorded in ADR 0041: an approved fork PR
still executes on the `gate` hosts, so approving one on a public repository is a
security-relevant action rather than a routine courtesy.
