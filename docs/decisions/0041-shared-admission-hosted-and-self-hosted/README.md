# 0041 — Both hosted and self-hosted serve both public and private repositories

- **Date:** 2026-08-01
- **Issue:** [Verjson/.github#270](https://github.com/Verjson/.github/issues/270)
- **Supersedes in part:** ADR 0028 decision 4 (GCP group must move to selected trusted
  repositories; public repositories may not hold persistent-runner access)
- **Extends:** [ADR 0040](../0040-runner-lanes-and-admission-axes/README.md) (lanes and axes)

## Context

ADR 0028 decision 4 held that runner-group access is the authorization boundary, that the
GCP group must move from all-repository/public access to **selected trusted
repositories**, and that a public repository "cannot regain persistent-runner access
without a new reviewed exception."

The live organization does not implement that (how long it has been so is undetermined —
`/orgs/Verjson/audit-log` returns 404 for this token, as ADR 0040 records):

```console
$ gh api /orgs/Verjson/actions/runner-groups/4 \
    --jq '{name,visibility,allows_public_repositories,selected_repositories_url}'
{"name":"GCP","visibility":"all","allows_public_repositories":true,"selected_repositories_url":null}
```

ADR 0040 recorded this as a discrepancy and #270 asked for a resolution: restore the
boundary, or consciously accept the wider admission and say so. **This ADR is the second
option, chosen deliberately by the owner.**

**The reason for superseding decision 4 is throughput and operational simplicity, stated
below — not hosted availability.** An earlier draft of this ADR argued that ADR 0028
assumed hosted was not a real option, and that is simply wrong. ADR 0028 says the
opposite: "isolation takes precedence over the former 'hosted last resort' preference,"
and its decisions 1 and 6 route untrusted and public work *to* `ubuntu-24.04`. "Last
resort" is **ADR 0003's** framing (it is in that ADR's title), and "hosted is unfunded, a
guaranteed failure" is **ADR 0033's**, which ADR 0040 corrects with billing evidence.

That correction is real, but it is an argument against ADR 0003 and ADR 0033. Decision 4
was about *admission*, not about hosted availability, so it needs its own argument. The
mistake is recorded rather than quietly deleted because superseding a security decision
with a misattributed rationale is the kind of error that survives review by sounding
plausible.

One thing has genuinely changed since ADR 0028: the fleet moved from GCP to DigitalOcean
(owner-reported; the runner labels still read `gce`/`GCP`, which ADR 0040 records as wrong
rather than legacy).

## Decision

**GitHub-hosted and DigitalOcean self-hosted runners both serve both public and private
repositories, for the foreseeable future.** Runner group 4 stays `visibility: all` with
`allows_public_repositories: true`. This is the intended steady state, not a pending
remediation.

**Capacity and provider changes are variable changes.** Spinning up additional runners,
moving load onto GitHub-hosted, or introducing a new provider is expressed by changing a
`VERJSON_LANE_*` variable — never by editing `runs-on:` in a workflow, and never by
hardcoding a pool, a label, or a runner group name anywhere in a repository. This is the
operative rule of ADR 0040 restated as a standing constraint on how this decision may be
revised: the lane variables are the only place topology is allowed to live.

Because of that, reversal needs **no workflow edits and no consumer migration** — a runner
group setting plus a variable change. It is not free, though: group 4 has zero selected
members today, so flipping it to `visibility: selected` de-admits every repository at once,
and an omitted repository queues forever with no check run. An admission inventory comes
first; see Rollback.

### Two different things are called "default" — keep them apart

Conflating these is a live hazard, so they are named separately here.

| | **GitHub's default runner group** | **Verjson's default lane** |
|---|---|---|
| What | Runner group 1, `default: true` | `VERJSON_LANE_FALLBACK` |
| Governs | Where a runner **registers** if `--runnergroup` is omitted | Where a **job runs** when no more specific lane is set |
| Owned by | GitHub; a custom group cannot be made default | Us |
| Changeable | No | **Yes — it is a variable** |

Group 1 is named `GitHub`, that name is correct, and it is **never renamed** — it names
GitHub's own default group and nothing else. It is *not* Verjson's default.

**Verjson's default must be switchable, and it is not GitHub-hosted by definition.** The
default lane is a variable, so it can point at the DigitalOcean self-hosted pool, at
hosted, or at a future provider, and switching it is a one-line organization-variable
edit. Nothing about the word "default" ties our routing default to GitHub's
infrastructure.

The terminal `'["ubuntu-24.04"]'` in the canonical expression is **not** the default
either — it is the portability contract for callers outside this organization, who have
no `VERJSON_LANE_*` set at all (ADR 0040). Our default is whatever
`VERJSON_LANE_FALLBACK` says.

The remaining trap is the *registration* default: a runner registered without
`--runnergroup` lands in group 1, which is public-accessible and has no label discipline.
That is a provisioning-time concern, unrelated to routing.

**Nothing checks for this automatically.** `scripts/ci-gate/runner-admission-reconcile.sh`
verifies repository admission and that each lane resolves to at least one online runner; it
has no runner-placement logic and does not look at group 1 or at `.default`. Placement must
be verified by hand after registering a runner. Adding that check is tracked in #275 — it is
named here as a gap rather than described as a control that exists.

## The North Star — what best practice would be, and why we are not doing it

This is recorded deliberately and in full, because an accepted deviation that is not
written down stops being a decision and becomes an accident. The target state, if
constraints allowed:

1. **Untrusted code executes on disposable hosts.** Fork and public pull-request jobs run
   on ephemeral one-job runners that are destroyed after use, so nothing persists between
   a hostile job and the next one.
2. **Admission is narrow.** The persistent pool is `visibility: selected` over trusted
   repositories; public repositories are denied by group visibility, which is
   organization-side and cannot be selected by whoever writes a pull request.
3. **The merge gate does not share hosts with untrusted code.** The privileged token that
   can merge pull requests runs on separate capacity from anything executing PR content.
4. **No ambient credentials or shared filesystem** on any host reachable by untrusted code
   — no shared caches, no persistent Docker socket state, no cloud credentials.

**Why we deviate:** a single shared persistent pool is materially faster (warm caches, no
per-job provisioning latency) and much simpler to operate at this size, and the owner has
prioritized CI throughput. Splitting the fleet costs either money for idle isolated
capacity or wall-clock for ephemeral provisioning, and the organization is not at a scale
where that trade pays for itself yet.

**What we accept as a consequence.** These are real, and stated plainly rather than
softened:

- Untrusted pull-request code from public repositories executes on persistent hosts with a
  reused filesystem, alongside private-repository work.
- All six live runners carry the `gate` label, so the merge gate — holding a token that can
  merge pull requests — runs on the same hosts as that untrusted code.
- A compromise of one job can persist to affect later jobs on the same runner, which is
  precisely the risk ADR 0028 decision 4 was written to remove.
- **The org-side admission layer is a no-op for group 4, so what actually gates fork code
  is per-repository fork-PR approval policy.** This is the consequence that most needs
  stating, because ADR 0040 calls group visibility "enforced org-side, unbypassable" — true
  as a mechanism, but a group at `visibility: all` with `allows_public_repositories: true`
  enforces nothing. ADR 0033 was safe against caller-supplied labels *because*
  `allows_public_repositories` was `false`; that protection is gone.

  It matters because `ai-review-merge.yml:163` and `:509` place caller-controlled
  `inputs.runner_labels` **first** in the `runs-on` precedence chain, and on a
  `pull_request` event that file is read from the PR head.

  **The attack surface was reduced on 2026-08-01 in response to this finding.** When first
  measured there were four public repositories, three of them at `first_time_contributors`
  — meaning a contributor approved once could run fork-head workflow content on the six
  hosts carrying `gate`, with no further approval. The owner narrowed it:
  `verjson-browser-agent` and `agents` were made **private** (neither had forks, stars,
  pages, packages, or meaningful CI usage, so nothing detached), and fork-PR approval was set
  to `all_external_contributors` everywhere it applies. Verified after the change:

  ```console
  $ gh api /orgs/Verjson/repos --paginate \
      --jq '"public=\([.[]|select(.archived==false and .private==false)]|length)"'
  public=2

  $ for r in .github verjson-github-runner; do printf '%s ' "$r"; \
      gh api "repos/Verjson/$r/actions/permissions/fork-pr-contributor-approval" \
        --jq .approval_policy; done
  .github all_external_contributors
  verjson-github-runner all_external_contributors
  ```

  Per-repository settings alone left a hole: the **organization default** was still
  `first_time_contributors`, so the next public repository would have inherited the weaker
  policy silently — a control described here as load-bearing, defaulting open for anything
  created after this ADR. The organization default was therefore raised to match:

  ```console
  $ gh api /orgs/Verjson/actions/permissions/fork-pr-contributor-approval
  {"approval_policy":"all_external_contributors"}
  ```

  `.github` stays public deliberately — it is consumed by other organizations Verjson works
  with (ADR 0022).

  **Residual risk, which is what remains accepted.** `all_external_contributors` requires a
  maintainer to approve *every* fork-PR workflow run from a non-collaborator, so exposure is
  now gated on a human approval rather than on a one-time trust decision. But an approved
  run still executes fork-head content on the `gate` hosts, and the escalation path is
  unchanged: persistence on a `gate` host → the merge-gate token → organization-wide merge
  authority. Approving a fork PR on a public repository is therefore a
  **security-relevant action**, not a routine courtesy. There is also the shared-capacity
  effect ADR 0033 noted — heavy CI can starve the gate.

  **Per-repository fork-PR approval and the count of public repositories are load-bearing
  security controls, recorded here as such**, in a table, for the same reason ADR 0033
  tabulated its organization settings: so that changing one is visible. Making a repository
  public, or relaxing its approval policy, re-opens the surface above and should be treated
  as a change to this ADR. (ADR 0033's "public repositories are exactly two" is, after this
  change, true again — but by a different route than it meant.)

[#204](https://github.com/Verjson/.github/issues/204) remains **open as the North Star
hook**, not as a defect report. It should not be closed as "won't do"; it is the tracking
issue for items 1–4 above if and when the trade changes.

## Consequences

- ADR 0028 decision 4 is superseded here. Its decisions **2, 3, and 5** — cache boundaries,
  immutable third-party action pins, least-privilege PR tokens — are untouched and still
  stand.

  Two others are **already not in force**, and are named explicitly rather than folded into
  a blanket "the rest still stands," because a reader checking ADR 0028 would otherwise take
  them as current:
  - **Decision 1** (the three-tier classification) put public repositories and fork PRs on
    an *isolated* tier and trusted work on "selected private repositories on the persistent
    GCP pool." Both halves are dead: the isolated group returns 404, and group 4 is not
    selected. ADR 0040 replaces the tiering with lanes.
  - **Decision 6** (`.github`'s validation and merge-gate executions use fixed
    `ubuntu-24.04`; public target repositories run the central merge gate on hosted
    capacity) is not in force: `ai-privileged-merge.yml` and `ai-review-merge.yml` route
    every `Verjson` caller, including the public `.github`, to self-hosted. ADR 0030's
    supersession is scoped to hosted routing **for Verjson public validation** and does not
    cleanly cover decision 6's public-gate clause.
- Runner group **names** may now describe admission honestly. Naming group 4
  `public-allowed` no longer bakes in a state the record says should not exist; it
  describes a decision.
- `VERJSON_LANE_UNTRUSTED` resolves to the self-hosted pool. Hosted is free and unmetered
  for public repositories, but a *private* repository on hosted rides a spending limit —
  ADR 0040 measures paid Actions usage stopping at exactly $20.00 — and past it, jobs fail
  fast with an empty runner name. A lane variable is organization-wide and cannot differ by
  repository visibility, which is deliberate: removing that coupling is the point of
  ADR 0040. So the value is chosen for the case that can fail.

  This is **not** a pending question blocking anything. Whether the spending limit is
  raised is a budget decision on its own timeline, and this design deliberately does not
  depend on it: if the limit changes, pointing the lane at hosted is a one-variable edit,
  and if it never changes, the current value is already correct. That independence is the
  point of putting topology in variables.
- No workflow changes. This ADR records an organization-configuration decision and a
  standing constraint; it alters no `runs-on:` anywhere.

## Rollback

Set group 4 to `visibility: selected`, admit the trusted repositories explicitly, and set
`allows_public_repositories: false`. Then point `VERJSON_LANE_UNTRUSTED` at hosted or at a
new isolated pool. Inventory current consumers **before** narrowing: a repository that
loses admission does not fail, it queues forever with no check run (#182's silent mode).
The scheduled reconciler's under-admission check exists to catch exactly that.
