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

The live organization does not implement that, and has not for some time:

```console
$ gh api /orgs/Verjson/actions/runner-groups/4 \
    --jq '{name,visibility,allows_public_repositories,selected_repositories_url}'
{"name":"GCP","visibility":"all","allows_public_repositories":true,"selected_repositories_url":null}
```

ADR 0040 recorded this as a discrepancy and #270 asked for a resolution: restore the
boundary, or consciously accept the wider admission and say so. **This ADR is the second
option, chosen deliberately by the owner.**

Two things changed since ADR 0028 that make the original decision less compelling than it
was. The fleet moved from GCP to DigitalOcean, and hosted runners turned out to be
available rather than unfunded — ADR 0040 corrects that premise with billing evidence.
ADR 0028's "hosted as last resort" framing assumed hosted was not a real option.

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

Because of that, this decision is cheap to reverse. Narrowing admission later is a runner
group setting plus a variable change; it needs no workflow edits and no consumer
migration.

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

[#204](https://github.com/Verjson/.github/issues/204) remains **open as the North Star
hook**, not as a defect report. It should not be closed as "won't do"; it is the tracking
issue for items 1–4 above if and when the trade changes.

## Consequences

- ADR 0028 decision 4 is superseded. ADR 0028's other decisions — cache boundaries,
  immutable third-party action pins, least-privilege PR tokens — are untouched and still
  stand. ADR 0030 already superseded ADR 0028 on hosted routing.
- Runner group **names** may now describe admission honestly. Naming group 4
  `public-allowed` no longer bakes in a state the record says should not exist; it
  describes a decision.
- `VERJSON_LANE_UNTRUSTED` continues to resolve to the self-hosted pool for now. Hosted is
  free and unmetered for public repositories, but a *private* repository on hosted rides a
  spending limit — ADR 0040 measures paid Actions usage stopping at exactly $20.00 — and
  past it, jobs fail fast with an empty runner name. A lane variable is organization-wide
  and cannot differ by repository visibility, which is deliberate: removing that coupling
  is the point of ADR 0040. So the value is chosen for the case that can fail. **Raising or
  removing the spending limit makes hosted viable for the untrusted lane, and at that point
  the change is a single variable edit.**
- No workflow changes. This ADR records an organization-configuration decision and a
  standing constraint; it alters no `runs-on:` anywhere.

## Rollback

Set group 4 to `visibility: selected`, admit the trusted repositories explicitly, and set
`allows_public_repositories: false`. Then point `VERJSON_LANE_UNTRUSTED` at hosted or at a
new isolated pool. Inventory current consumers **before** narrowing: a repository that
loses admission does not fail, it queues forever with no check run (#182's silent mode).
The scheduled reconciler's under-admission check exists to catch exactly that.
