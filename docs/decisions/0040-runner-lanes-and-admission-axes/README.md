# 0040 — Lanes name the work; groups enforce admission

- **Date:** 2026-08-01
- **Issues:** [Verjson/.github#256](https://github.com/Verjson/.github/issues/256),
  [Verjson/.github#203](https://github.com/Verjson/.github/issues/203),
  [Verjson/.github#204](https://github.com/Verjson/.github/issues/204)
- **Supersedes:** ADR 0033's visibility-tier routing model, and corrects its funding premise
- **Extends:** ADR 0035 (variable-driven lanes), ADR 0036 (privileged merge separated from review)

## Context

Four routing defects — #175, #182, #192, and `verjson-infra` PR #77 — share one root
cause, and the documents describing the system would have produced a fifth.

**Routing policy is written as a conditional expression embedded in `runs-on:`,
duplicated across nine jobs, encoding facts that live somewhere else.** ADR 0033
diagnosed this exactly, about its own predecessor: the allowlist "encodes in workflow
YAML a fact that lives in org settings, so it is stale by construction." It then
replaced that allowlist with a four-tier expression encoding two *more* external facts —
repository visibility and billing state.

Both of those facts are now wrong, which is the argument for this decision.

### How to read the claims in this document

An accepted ADR records what was decided and what was true **when it was written**. It is
not a standing warrant that those facts still hold, and three of ADR 0033's have since
gone stale without anyone noticing — which is how the documents came to describe a
topology that no longer exists.

So this document treats no inherited claim as true. Every figure below was re-derived from
a live `gh api` call on 2026-08-01, with the command quoted so it can be re-run rather
than believed. Where something could not be verified — a deleted resource, an
unavailable audit trail, software on a runner host — it is labelled as reported or
asserted, and *not* promoted to a finding. The same standard applies to this ADR: re-run
the queries before relying on it.

### Correction 1 — the funding premise is false

ADR 0033 asserts that "GitHub-hosted minutes are unfunded for this organization (#189)"
and that `ubuntu-24.04` is "a guaranteed failure, not a fallback." That is false for
public repositories and misleading for private ones.

```console
$ gh api '/organizations/Verjson/settings/billing/usage?year=2026&month=7' | jq '
    [.usageItems[] | select(.sku == "Actions Linux")]
    | {first_paid: ([.[] | select(.netAmount > 0) | .date] | min),
       last_paid:  ([.[] | select(.netAmount > 0) | .date] | max),
       total_net:  ([.[] | .netAmount] | add),
       total_min:  ([.[] | .quantity]  | add | round)}'
{
  "first_paid": "2026-07-13T00:27:10Z",
  "last_paid":  "2026-07-17T08:52:13Z",
  "total_net":  20.000000000000004,
  "total_min":  7514
}
```

Paid usage stops at **exactly $20.00**, to the cent. That is a spending **limit**, which
is a budget knob — not an architectural impossibility. Paid usage *beginning* on 07-13 is
the monthly free allowance running out.

After the cutoff, hosted minutes still run, fully discounted
(`grossAmount == discountAmount`, `netAmount: 0`), and **not only for public
repositories**: private `toquorum`, `sitenav`, and `verjson-payments` each drew 2–4
discounted minutes through 07-31. Public repositories run hosted freely and at volume —
`verjson-github-runner` burned 836 minutes at `$0` in the back half of July.

Reading aggregate `netAmount` alone hides all of this, because "free" and "refused" both
render as `$0`. Group by `netAmount > 0` when re-running this.

The month=8 query returns only storage accruals so far and is not yet informative.

This premise is load-bearing in several decision records. It is corrected here, once,
with the query quoted so the next reader can re-run it rather than inherit it.

### Correction 2 — group 4 was widened out of band

ADR 0033's Consequences describe group 4 as `visibility: selected` with 82 admitted
repositories. It is not:

```console
$ gh api /orgs/Verjson/actions/runner-groups/4 \
    | jq '{id,name,visibility,allows_public_repositories,selected_repositories_url}'
{ "id": 4, "name": "GCP", "visibility": "all",
  "allows_public_repositories": true, "selected_repositories_url": null }

$ gh api '/orgs/Verjson/actions/runner-groups/4/repositories?per_page=100' --paginate \
    --jq '.repositories[].full_name' | wc -l
0
```

The group is now organization-wide, admits public repositories, and has zero selected
members. **No ADR records this change.** Who made it, when, and why are all
undetermined: `/orgs/Verjson/audit-log` returns 404 for this token — whether because the
plan does not expose it or because the token lacks the scope is itself unresolved, and
either way no attribution is available. The "after 2026-07-29" bound comes from the
reporting that opened this work, not from a measurement.

Stating the gap plainly is the honest record. Inventing a rationale would be worse than
the gap, and this document holds itself to that in the retirement section below.

### Correction 3 — the Docker lane does not exist

`docs/runner-routing.md` required Docker/kind/buildx work to pin `[self-hosted, docker]`
on `gha-docker-1`, and asserted "the general GCP pool has no Docker socket."

```console
$ gh api /orgs/Verjson/actions/runners --jq '[.runners[].name] | join(", ")'
gha-general-1, gha-general-2, gha-general-3, gha-general-4, gha-general-5,
gha-general-6, hostinger

$ gh api /orgs/Verjson/actions/runners \
    --jq '[.runners[] | select([.labels[].name] | index("docker"))] | length'
0
```

`gha-docker-1` is absent from the fleet and **no runner in the organization carries a
`docker` label**. Both of those are measured. The further claim that every live
self-hosted runner has Docker Compose is **the owner's, and is not independently verified
here** — runner-local software is not visible through the API, and confirming it means
running a job on the pool. It is recorded as an owner assertion, not as a finding.

Either way the lane is unroutable today, so it is retired. The no-socket claim is marked
retired rather than deleted, because it was load-bearing for earlier decisions and a
silent deletion would strand them.

### The 2026-07-31 retirement — recorded here, with its rationale still missing

What is **measured**: runner groups `6` and `7` both return 404, and the live fleet is six
`gha-general-*` runners plus `hostinger`. What is **reported to this decision but not
independently verifiable**: that the groups were named `isolated` and `docker-builders`,
that ten runners were deregistered, and that this happened on 2026-07-31. A deregistered
runner and a deleted group leave no API trace, and `/orgs/Verjson/audit-log` returns 404
for this token, so none of that can be confirmed after the fact.

**The rationale for the retirement is not on the record, and this ADR does not supply
one.** It would be easy to write "the GCP-era pools were at size zero after the
DigitalOcean migration" — that is plausible, consistent with the fleet, and entirely
unevidenced. Inventing it here is precisely the failure this document criticises two
sections above, and a fabricated rationale in an ADR is worse than an acknowledged gap,
because it reads as established once the context is gone. The owner should amend this
section with the actual reason.

The consequence is on the record regardless: the reconciler pinned group 6 by id and went
undetermined on every run until #266.

## Decision

### Lanes are the primary abstraction

A workflow declares **what kind of work this is**. Organization configuration decides
**what machine that means**. Lanes replace `VERJSON_RUNNER_*` entirely.

| Lane variable | Meaning | Today | Later |
|---|---|---|---|
| `VERJSON_LANE_UNTRUSTED` | fork/PR code, no secrets | self-hosted (see below) | hosted, permanently |
| `VERJSON_LANE_TRUSTED` | organization code, secrets available | self-hosted | either |
| `VERJSON_LANE_PRIVILEGED` | merge gate, elevated token | self-hosted | isolated pool |
| `VERJSON_LANE_FALLBACK` | organization-wide fallback | configurable | configurable |

Canonical expression:

```yaml
runs-on: ${{ fromJSON(vars.VERJSON_LANE_TRUSTED || vars.VERJSON_LANE_FALLBACK || '["ubuntu-24.04"]') }}
```

Two organization-config knobs before any literal. Compare the ~200-character four-tier
expression duplicated across nine jobs today: no owner check, no visibility check, no
billing assumption.

**The terminal literal is a portability contract, not a fallback.** `vars` resolves in the
*caller's* context, so an outside organization calling a Verjson reusable workflow has no
`VERJSON_LANE_*` set and lands on hosted automatically — the only sane default for someone
with no self-hosted fleet.

This distinction is the lesson of ADR 0033's failure. It treated a terminal literal as a
*safety net* — "it'll land on hosted if something's wrong" — when hosted was, for private
repositories at the time, a guaranteed failure. A terminal that means **"you configured
nothing"** is honest. A terminal that means **"something went wrong, try this"** is a trap,
because it fires precisely when the system is least able to cope.

`VERJSON_LANE_PRIVILEGED` is defined now even though it resolves to the same pool as
`TRUSTED`. A collapsed lane costs nothing and is the seam isolation will need. The
boundary it names is not merely asserted by ADR 0036 — it is observable in the running
system: `ai-review-merge.yml` dispatches a separate `ai-privileged-merge.yml` run, which
re-validates the head SHA and its trust anchor before merging (observed on run
`30684964896`, 2026-08-01). Routing is being aligned to a split that already exists in
behaviour.

**`UNTRUSTED` points at self-hosted, not hosted, despite hosted being available.** Hosted
is free and unmetered for public repositories, but a *private* repository reaching hosted
rides the $20 ceiling documented above; past it, jobs fail fast with an empty runner name
— precisely `verjson-infra` PR #77's signature. Until the lane can be resolved per
repository visibility (which is the very coupling this ADR removes from `runs-on`), the
safe value is the self-hosted pool. Revisit when the spending limit is deliberately set.

### Three axes underneath the lanes

| Axis | Mechanism | Values | In `runs-on`? |
|---|---|---|---|
| Admission / trust | runner **group** visibility | private-only vs public-allowed | **no** — enforced, not selected |
| Capability | **label** | `general`; `docker` if reintroduced | yes |
| Provider / host | operational attribute only | `do`, `hostinger` | **never** |

**A label cannot carry a security boundary.** `runs-on` lives in the workflow file, which
a pull request can edit, so any label is selectable by whoever writes the PR. Only group
visibility is organization-side and unbypassable. That is why admission is groups, and why
there is no `secure`/`insecure` label — such a label would be a boundary its own attacker
gets to choose.

### Where each check belongs

| Tier | Runs | Checks | Token |
|---|---|---|---|
| Resolver job (later phase) | per job, hot path | lane variable exists, well-formed non-empty JSON array | none |
| Reconciler | scheduled, trusted | every lane resolves to ≥1 **online** runner | `ORG_ADMIN_TOKEN` |
| Required workflow (ruleset) | per PR, organization-wide | no workflow hardcodes `runs-on` | none |

Availability checking is deliberately **not** on the hot path. Fork pull requests receive
no organization secrets, so an API-validating resolver would have no token in exactly the
untrusted case it most needs to cover. A runner online at resolve time may be offline at
dispatch, so the check is stale the moment it passes. And normalizing an org-admin token
call into 89 repositories' pull-request paths widens the blast radius of that token
enormously. Availability is a fleet-level fact; it belongs in the scheduled reconciler,
which already holds the token in a context that never executes pull-request code.

## Consequences

- The three current variables (`VERJSON_RUNNER_DEFAULT`, `_ISOLATED`, `_UNTRUSTED`) are
  **deliberately collapsed** onto one pool — all three are `["self-hosted","general"]`
  today. The names describe an isolation topology that is defined but not enforced. This
  is intentional and pending, not an oversight; #204 is the restoration hook.
- **`gce` and `GCP` on the six live runners are wrong, not merely legacy.** Those are
  DigitalOcean machines. The correction is sequenced, not deferred: add `do` labels
  additively, then sweep inline `runs-on` (#203), then delete the stale labels. Deleting
  them before the sweep makes those jobs queue forever with no check run — #182's silent
  mode, the failure this programme exists to eliminate.
- **Accepted risk:** the six live runners carry `gate`, so the AI merge gate — holding a
  token that can merge pull requests — executes on the same hosts as untrusted pull-request
  code. The owner has deferred isolation to protect CI speed and wants automerge
  maximized. This is recorded as a decision on the record, with #204 as the hook, not as an
  open objection.
- Group ids remain the identity for admission; admitted repositories travel with the id
  across a rename. Renaming groups onto the admission axis is therefore safe with respect
  to who is admitted — but group **names** are referenced at runner registration
  (`--runnergroup <name>`), so a rename can break provisioning in repositories outside this
  one.

## Open question — owner's call, deliberately not decided here

Whether `.github`'s own privileged merge workflows should move to hosted runners, now that
hosted is confirmed available and free for public repositories. `.github` is public, so
the $20 ceiling does not apply to it.

The trade-off: a disposable hosted VM is exactly the isolated lane the organization would
otherwise have to build and pay for, and it would resolve the accepted risk above without
waiting on #204. Against that, it puts the merge-gate token on infrastructure the
organization does not control, and it costs the warm-cache speed the owner deferred
isolation to protect. This is a topology decision with a security dimension, so it is the
owner's, and it is left open rather than settled by a documentation PR.

## Rollback

This ADR changes no runner topology and no organization configuration; it is a model plus
corrections to the record. Reverting the implementing PR restores the previous document.
The lane variables it specifies are created in a later, separately reversible change.
