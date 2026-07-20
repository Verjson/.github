# 0016 — Self-gate runner lane must be redundant (second dedicated `meta` runner)

- **Date:** 2026-07-20
- **Issue:** Verjson/.github#70 (self-gate runner SPOF)
- **PR:** Verjson/.github#71
- **Category:** org Actions runner topology / CI infrastructure (sensitive class)
- **Relationship:** Formalises and extends the reserved-`meta`-lane decision first
  made in commit `64f84a6` (#14); operational reference is
  [`docs/runner-routing.md`](../../runner-routing.md); group structure is
  [ADR 0003](../0003-runner-groups-gcp-github-manish/README.md).

## Context

PRs to `Verjson/.github` fix the CI pipeline itself. #14 reserved a dedicated
runner lane (`runs-on: [self-hosted, meta]` when
`github.repository == 'Verjson/.github'`) so those fixes never queue behind bulk
or other-repo gate work — a pipeline fix once "waited hours behind runs hanging
on the very bug it fixes." The runner `gha-meta-1` registers with **only** the
`meta` label, so bulk CI can never occupy it. That dedication is correct and
stays.

The lane is served by a **single** runner, which makes it a single point of
failure:

- If `gha-meta-1` is offline, **every** self-gate job (`freshness`, `classify`,
  `ai-review`, `ai-merge`) has nowhere to run and `.github` PRs sit un-gated.
- A single self-gate run's four jobs **serialize** on the one runner (observed as
  gate congestion while landing a fanned-out batch this session).
- `gha-meta-1` is **not** a GCE box (labels `self-hosted,Linux,X64,meta` only),
  so it cannot resolve private composite actions — which is why the self-gate
  lane carries no OTLP telemetry (`docs/runner-routing.md` constraint 3).

## Decision

The self-gate lane **must be redundant**: at least two runners, each registered
**`meta`-only** so the #14 "bulk CI can never occupy the lane" invariant holds.

Provision a second dedicated runner, **`gha-meta-2`**, as a **GCE** VM:

1. GCE image → ambient `gh`/git and the ability to resolve private composite
   actions (strictly better than the non-GCE `gha-meta-1`; unblocks self-gate
   telemetry as a follow-on).
2. Registered with the **`meta` label only** — never `GCP`/`gce`/`gate` — so
   bulk and org-gate work can never land on it.
3. Moved into the `GCP` runner **group** after registration (a newly registered
   runner auto-lands in the `GitHub` default group — ADR 0003 caveat).

**No workflow change is required**: `runs-on: [self-hosted, meta]` already
selects any runner carrying the `meta` label, so `gha-meta-2` joins the lane the
moment it registers. This ADR + PR carry the decision and the operational-doc
update; **provisioning the VM is an on-box / cloud-console step owned by the
runner-topology owner** and is tracked by #70.

### Rejected alternatives

- **Fold the self-gate into the shared `gate` pool** (`runs-on: [self-hosted,
  gate]` for `.github` too). Rejected: it reintroduces exactly the #14
  chicken-and-egg — `.github` pipeline fixes would again queue behind every other
  repo's gate work. The extra capability of the `gate` runners does not justify
  losing the dedicated lane.
- **Relabel an existing runner `meta`-only via the org API** (e.g. move a
  `gha-runner-*` from `GCP` into the meta lane). Rejected as the primary fix: it
  shrinks the general-CI pool, which is already degraded (`gha-runner-6` offline
  at time of writing → 3 online general runners), and trades one SPOF for reduced
  general throughput. A dedicated new VM adds capacity instead of moving it.

## Consequences

- Once `gha-meta-2` is live, a single meta-runner outage no longer un-gates
  `.github`, and a self-gate run's four jobs can run two-wide instead of
  serializing — removing the observed congestion.
- The #14 dedication invariant is preserved: both meta runners are `meta`-only,
  so bulk/gate CI still cannot occupy the lane.
- Follow-on (not required here): making the meta lane GCE-capable lets the
  self-gate emit OTLP telemetry like the other lanes; `gha-meta-1` can then be
  replaced or upgraded to GCE for parity.
- Until `gha-meta-2` is provisioned, the SPOF stands; #70 stays open to track it.

## Effective change (runner topology)

No workflow diff — the selector is unchanged and label-driven:

```yaml
# ai-review-merge.yml (unchanged): self-gate stays on the dedicated meta lane
runs-on: ${{ github.repository == 'Verjson/.github' && fromJSON('["self-hosted","meta"]') || fromJSON('["self-hosted","gate"]') }}
```

Topology change (org Actions settings, performed out-of-band by the runner-topology owner):

```text
- meta lane: gha-meta-1                       (1 runner — SPOF)
+ meta lane: gha-meta-1, gha-meta-2 (GCE)     (2 dedicated meta-only runners)
```

Full change / rationale: Verjson/.github#71.
