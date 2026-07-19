# 0011 — Runner labels describe capability: drop `GCP` from the `hostinger` runner

- **Date:** 2026-07-19
- **Issue:** Verjson/.github#52 (gate `gh: command not found` incident)
- **PR:** Verjson/.github (this doc); the label change itself was applied via the
  org runners API (not git-versioned — see the diff block below)
- **Category:** Runner topology (sensitive class)
- **Relationship:** root-cause complement to the gate routing fix #53; extends
  ADR 0003 (runner groups) and `docs/runner-routing.md`.

## Context

The self-hosted runner `hostinger` carried the labels `[self-hosted, GCP, manish]`
— but it is **not** a GCE VM (it is a Hostinger VPS, the `manish` overflow box) and
runs a different image **without the ambient toolchain** (`gh`, and no baked-in
Node) that the GCE runners have.

The `GCP` label was doing double duty — *"this is a GCE VM"* **and** *"this has the
ambient gh/git/node toolchain"* — and `hostinger` satisfied neither while wearing
it. So `[self-hosted, GCP]` was a **superset** of `[self-hosted, gce]`: any `GCP`
job could be scheduled onto `hostinger`. That broke the merge gate's `classify`
step with `gh: command not found` (#52), and would silently break any `GCP` job
that assumes ambient tooling.

We still want `hostinger` **available as a runner option** — it is real overflow
capacity — just labelled truthfully so jobs opt into it knowingly.

## Decision

1. **Remove `GCP` from `hostinger`.** Its labels are now
   `[self-hosted, Linux, X64, manish]`. `GCP` (and `gce`) once again denote **only**
   the GCE-image runners with the ambient toolchain — `GCP` ≡ `gce`, no superset gap.
2. **`hostinger` stays a first-class option via its accurate `manish` label.** Jobs
   that want the overflow box target `[self-hosted, manish]` explicitly (e.g.
   `toquorum/.github/workflows/deploy.yml` already does), and such jobs must
   self-provision their tools (Node via `setup-node`, etc.) rather than assume an
   ambient toolchain.
3. **Promotion path (not done here):** to let `hostinger` serve *general* overflow
   for the `GCP`/`gce` pools, provision `gh` + git on the box to reach toolchain
   parity, then it can rejoin a shared capability label. Until then it is
   explicit-opt-in via `manish`. This is on-box provisioning owned by the
   runner-topology owner.
4. **Labels describe capability, not just provider.** New runners join `GCP`/`gce`
   only if they carry the GCE toolchain; otherwise they get a purpose/identity label
   (`manish`, `docker`, `meta`, …). The gate keeps its dedicated `gate` subset (#53).

## Consequences

- `[self-hosted, GCP]` jobs no longer land on a toolchain-less box; the #52 class of
  `command not found` failures is fixed at the source. The gate routing fix (#53,
  freshness/classify → `gate`) remains as consistency + isolation, now belt-and-braces.
- `GCP` loses `hostinger` as overflow capacity (8 GCE runners remain). If that
  capacity is needed back, the promotion path (provision `gh`) is the route.
- `hostinger` is unaffected for its explicit `manish` consumers.
- The label change is a live API mutation, not a git revert; to undo, re-add the
  label via the runners API (recorded below).

### Effective change (sensitive hunk — org runners API, runner id 22)

```diff
- hostinger labels: [self-hosted, Linux, X64, GCP, manish]
+ hostinger labels: [self-hosted, Linux, X64, manish]
```

Applied with:
`gh api -X DELETE orgs/Verjson/actions/runners/22/labels/GCP`
Revert with:
`gh api --method POST orgs/Verjson/actions/runners/22/labels -f "labels[]=GCP"`
