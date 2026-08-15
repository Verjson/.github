# 0103 — OS-scoped hosted lanes are repository-scoped, bounded, and fail closed

- **Date:** 2026-08-15
- **Issues:** [#810](https://github.com/Verjson/.github/issues/810),
  [#814](https://github.com/Verjson/.github/issues/814),
  [#815](https://github.com/Verjson/.github/issues/815),
  [#816](https://github.com/Verjson/.github/issues/816),
  [Verjson/AiB#229](https://github.com/Verjson/AiB/issues/229)
- **Extends:** [ADR 0040](../0040-runner-lanes-and-admission-axes/README.md) (lanes name the work),
  [ADR 0041](../0041-shared-admission-hosted-and-self-hosted/README.md) (capacity moves are variable edits)
- **Category:** CI routing and organization spend — **sensitive class**
- **Status:** Accepted

## Context

The organization is raising its GitHub Actions spending limit so `Verjson/AiB` can build
Electron installers on hosted macOS and Windows. That raise removes the thing that was
actually doing the containment. Until now, hosted spend was bounded because the limit
refused the jobs; afterwards nothing structural stops any of ~89 private repositories from
consuming hosted minutes, and the only remaining bound is whatever contract this
organization builds.

The guarantee this decision has to hold is narrow and absolute: **once the limit is
raised, the only jobs anywhere in the organization that may consume GitHub-hosted minutes
are AiB's macOS and Windows installer legs of a dispatched release.** Everything else —
all pull-request CI, all Linux work, every other repository — stays on the self-hosted
`general` lane, plus the two already-sanctioned `ubuntu-24.04` security-boundary jobs of
[ADR 0089](../0089-caller-supplied-privileged-routing/README.md), whose minutes
are free because `.github` is public.

ADR 0040 already records why a convention will not hold this. The hardcoded-selector
defect regrew four times under a documented convention (#175, #182, #192, #203). The
check that is supposed to be the control, `scripts/ci-gate/runner-routing-policy.test.sh`,
keyed every literal-selector assertion on `ubuntu-(24\.04|latest)` — so `runs-on:
macos-latest` passed the entire file. The two metered SKUs, at 10x and 2x multipliers, were
precisely the two it could not see.

## Decision

### The lanes, and their scope

| Variable | Value | Scope |
| --- | --- | --- |
| `VERJSON_LANE_TRUSTED_MACOS` | `["macos-15"]` | **repository variable on `Verjson/AiB` only** |
| `VERJSON_LANE_TRUSTED_WINDOWS` | `["windows-2025"]` | **repository variable on `Verjson/AiB` only** |

JSON arrays, so `fromJSON()` matches every existing lane usage. The names keep the
`VERJSON_LANE_*` prefix so the routing conformance check and the actionlint policy see a
lane rather than a new concept.

**They are not organization variables, and that is the containment primitive.** An
organization variable is readable by every repository in its visibility set, so defining
these at org scope would hand ~89 private repositories a working hosted selector and invite
exactly the copy-paste reuse ADR 0040 watched regrow four times. GitHub's runner *groups*
enforce admission for self-hosted capacity, but they do **not** scope standard hosted
labels — there is no group-shaped way to say "only this repository may ask for
`macos-15`". A repository-scoped variable is the strongest containment GitHub's model
actually offers here, and everything else in this decision is defence in depth behind it.

**The image is pinned; `-latest` is never used.** `macos-latest` and `windows-latest` roll
over on GitHub's schedule, which silently changes the toolchain, SDK, and signing
environment that produce a shipped installer. A release artifact whose build environment
can change without a commit is not reproducible.

### Fail closed, with no fallback tail

The ordinary chain — `VERJSON_LANE_TRUSTED || VERJSON_LANE_FALLBACK || '["ubuntu-24.04"]'`
— is correct for Linux work and actively wrong here. An unset macOS lane that degrades to
Ubuntu produces a non-installable artifact behind a green check. The OS lanes therefore
carry **no fallback tail**, which is a deliberate exception to ADR 0040's rule that every
lane selector falls through to `VERJSON_LANE_FALLBACK`. The conformance check encodes the
exception; the workflow does not evade the rule.

An unset OS lane cannot be turned into an explicit in-job error, because `runs-on` is
evaluated before any step exists: `fromJSON(vars.UNSET)` produces a workflow-level startup
failure naming neither the variable nor the fix, and an *empty* array is accepted by GitHub
and queues forever with no check-run diagnostic — the #401 failure mode one level up. The
legible shape is a preflight job on `VERJSON_LANE_TRUSTED` that asserts the OS lane
variables are well-formed, non-empty JSON, which is the resolver tier already documented in
`docs/runner-routing.md`. A repository that copies the workflow without the variables gets
a hard, readable failure on self-hosted Linux rather than free hosted minutes.

### Dispatch-only, bounded, and minimal

The hosted legs run only on `workflow_dispatch` under the canonical release contract
(ADR 0038, ADR 0060). Never `pull_request`, never `push`, never a tag push. That bounds
spend to release cadence — a handful of runs a month — rather than to pull-request volume.

`timeout-minutes` is **mandatory and bounded**: the lanes are configured at 45 minutes, and
the conformance ceiling is 60. A presence-only check is not sufficient, and this is the
part most likely to be softened by someone in a hurry: `timeout-minutes: 360` satisfies
"has a timeout" while being exactly the runaway the requirement exists to prevent — six
hours at macOS's 10x multiplier is up to 3,600 billable minutes from one hung step, from a
single dispatch.

A hosted job does one thing: install dependencies, build its own OS's installer, upload the
artifact. Version resolution, the changelog snapshot, tagging, verification, release
creation, and asset attachment all stay on self-hosted Linux. Minimizing hosted job
*content* bounds spend far more than minimizing job count. A hosted job also receives no
`secrets: inherit`; artifact upload needs no organization secret, and a hosted runner sits
outside the admission boundary that runner groups enforce for self-hosted capacity.

### `.github` does not grow a cross-platform release workflow

ADR 0060 retired `node-release.yml`, and the canonical release path is a dispatched
`changelog-release.yml` that **builds nothing**. AiB owns its own desktop release workflow.
So in this repository the sanctioned set for the OS lane variables is **empty**, and the
conformance rule is simply that no workflow here may reference them at all. The set is an
explicit constant in `scripts/ci-gate/hosted-selector-policy.sh` rather than an implicit
absence, so #815 extends it deliberately rather than by accident.

The check does **not** hardcode `github.repository == 'Verjson/AiB'`. A repository
allowlist inside a shared workflow would look stronger while making a second desktop
repository a pull request in `.github` instead of a variable edit — precisely the property
ADR 0041 exists to preserve. The repository-scoped variables already are the allowlist; the
reference rule only makes the inability visible instead of implicit, and gives one grep
that answers "who can spend hosted minutes".

### The metered-SKU ban has zero exceptions

Any `runs-on` naming `macos-*` or `windows-*` fails. No allowlist, no parameter, no
environment override. No security-boundary argument has ever required either family, unlike
the closed `ubuntu-24.04` inventory of ADR 0089 — which stands **unchanged**, still limited
to the credentialless invalid-route guard and the privileged conformance audit, and still
pinned by exact-site equality so it cannot grow silently.

### Two tiers, and why they differ

This is the part most likely to be re-litigated later as "the check is too noisy", so the
argument is settled here rather than in a future pull-request thread.

**Tier A — visibility-independent, zero exceptions.** The metered families are refused
regardless of what the repository is today, and `-latest` inside those families keeps its
own distinct message. Repository visibility is a *mutable organization-settings fact*.
Encoding it in a workflow file is exactly the "encodes in workflow YAML a fact that lives in
org settings, so it is stale by construction" defect ADR 0033 diagnosed and ADR 0040 saw
repeat. A public repository flipped private turns a free `macos-latest` job into a 10x
metered one with no commit, no review, and no signal — so a refusal that depended on
visibility would be silently wrong at exactly the moment it mattered.

**Tier B — visibility-keyed.** Literal Linux hosted selectors (`ubuntu-*`, including
`ubuntu-latest` and `ubuntu-24.04`) fail only when the target repository is private. Hosted
minutes are free for public repositories (measured 2026-08-01; ADR 0047 corrected ADR 0033's
"unfunded" premise), so the same line spends nothing in a public repository and rides the
spending limit in a private one.

A public repository still should not hardcode a hosted selector, and the remedy is not a
literal. The organization already has a sanctioned path for public work to reach hosted
capacity: `VERJSON_RUNNER_FASTLANE`, a **variable** (ADR 0047/0048), already carved out in
the routing check. Because it is a variable, a capacity or provider move stays an
org-variable edit rather than a pull request in ~89 repositories, which is the ADR 0041
property. A hardcoded `ubuntu-latest` reaches the same runner while giving that property
up. Enforcing that half for public repositories is #816; recording it here makes the
deferral a decision rather than an oversight. `.github` itself is held to the stricter
standard regardless, by its own ADR 0089 inventory, which this change does not touch.

## Consequences

- The metered SKUs are refused by a check rather than by a spending limit, which is what
  makes the limit raise safe.
- An OS lane that is unset fails loudly on self-hosted Linux instead of quietly shipping a
  Linux binary as a macOS installer.
- A hung hosted step costs at most 45 minutes of wall time rather than six hours of billing.
- One grep — for `VERJSON_LANE_TRUSTED_MACOS` or `VERJSON_LANE_TRUSTED_WINDOWS` — answers
  which workflows can spend hosted minutes.
- **Accepted cost:** a future second desktop repository needs its own repository variables
  rather than inheriting them. That gives up one property ADR 0041 exists to preserve, and
  it is deliberate friction: a second hosted consumer should be an explicit act, not an
  inherited default.
- The rules live in a parameterized script with fixture-driven tests, because this
  repository has no macOS or Windows selector and no OS-scoped lane — an assertion against
  the live tree could never fail and would prove nothing. #815 points the same script at
  consumer checkouts without duplicating it.

## Rejected alternatives

- **Organization-scoped OS lane variables.** Readable by every repository in the visibility
  set, which hands ~89 repositories a working hosted selector. This is the copy-paste vector
  ADR 0040 documents regrowing four times.
- **A repository allowlist inside the shared workflow.** Looks stronger, but moves a second
  desktop repository from a variable edit to a `.github` pull request, reversing ADR 0041.
- **A presence-only `timeout-minutes` check.** Passes `timeout-minutes: 360`, which is the
  runaway itself.
- **Reusing the ordinary lane chain for the OS lanes.** Degrades a macOS leg to Linux and
  ships a non-installable artifact behind a green check.
- **Extending the ADR 0089 allowlist to cover macOS or Windows.** No security-boundary
  argument has ever required a metered SKU; the two rules protect different things and the
  metered ban is unconditional.
- **Keying Tier A on repository visibility.** Encodes a mutable org-settings fact in
  workflow YAML, so it is stale by construction and fails open the moment a repository flips
  private.
