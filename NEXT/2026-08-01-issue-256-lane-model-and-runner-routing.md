---
date: 2026-08-01
issue: 256
title: Define the lane model and rewrite the runner-routing guide against measured state
---

`docs/runner-routing.md` described a topology that no longer exists — `gha-docker-1` and a
required `[self-hosted, docker]` lane, `gha-gate-*`/`gha-meta-*` runners, an `isolated`
group, and eight GCE VMs — while ADR 0033 asserted a funding premise that is measurably
false. Four routing defects (#175, #182, #192, `verjson-infra` PR #77) share one root
cause, and the documents as written would have produced a fifth.

[ADR 0040](../docs/decisions/0040-runner-lanes-and-admission-axes/README.md) records the
model: workflows declare **what kind of work this is** (a lane), organization configuration
decides **what machine that means**, and three axes sit underneath — admission enforced by
runner *group* visibility, capability by *label*, provider as an operational attribute that
never appears in `runs-on`. A label cannot carry a security boundary, because `runs-on`
lives in a file a pull request can edit. The terminal `'["ubuntu-24.04"]'` is documented as
a portability contract for outside callers, explicitly not a safety net — ADR 0033's
failure was treating a terminal literal as a fallback when it was a guaranteed failure.

Three claims are corrected against live queries, each quoted so it can be re-run: hosted
runners are **not** unfunded (public repositories run hosted at $0; organization-wide paid
Actions usage stopped at exactly $20.00, a spending limit rather than an architectural
impossibility); group 4 is `visibility: all` with zero selected members rather than
`selected` with 82; and no runner in the organization carries a `docker` label.

The group-4 finding was more than a documentation gap: the live configuration was a
reversion to ADR 0003's superseded state, leaving ADR 0028's admission boundary — public
repositories may not hold persistent-runner access — not in force, with no record of the
change.

[ADR 0041](../docs/decisions/0041-shared-admission-hosted-and-self-hosted/README.md)
resolves it in favour of the live state, deliberately: GitHub-hosted and DigitalOcean
self-hosted both serve public and private repositories for the foreseeable future, and
ADR 0028 decision 4 is superseded. It also records what best practice *would* be — ephemeral
hosts for untrusted code, narrow admission, a merge gate that does not share hosts with PR
content — as an explicit North Star, with the accepted risks stated rather than softened,
so the deviation stays a decision instead of decaying into an accident. #204 stays open as
the hook for that target, not as a defect.

The standing constraint that makes it reversible: **capacity and provider changes are
variable changes.** New runners, more hosted compute, or a new provider is a
`VERJSON_LANE_*` edit — never a `runs-on:` edit, and never a hardcoded pool, label, or
runner-group name.

Two things are deliberately **not** claimed. The rationale for the 2026-07-31 group
retirement is absent from the record and this ADR does not invent one — a fabricated
rationale reads as established once the context is gone. And the assertion that all live
runners have Docker Compose is recorded as the owner's, not as a finding, because
runner-local software is not visible through the API. The ADR opens by stating that an
accepted decision record is not a standing warrant that its facts still hold.

Documentation only: no workflow YAML and no organization configuration changed.
