# 0029 — Repurpose retired meta runners as private merge-gate capacity

- **Date:** 2026-07-28
- **Issue:** Verjson/.github#171
- **Category:** runner topology / merge-gate availability
- **Supersedes in part:** ADR 0016's dedicated `.github` meta-only lane

## Context

ADR 0016 created two `meta`-only runners so changes to the public `.github`
repository could review and repair their own pipeline without competing with
organization CI. ADR 0028 later moved `.github` and every public-target gate to
fixed GitHub-hosted capacity so public code cannot reach persistent runners.
The two meta runners are therefore idle.

Private-repository merge gates still target `[self-hosted, gate]`. During the
CI-throughput rollout, `Verjson/toquorum#283` completed its consolidated
application check in 7m49s but its gate preflight remained queued for more than
30 minutes on the four-runner gate lane. The idle meta machines already ran the
same gate implementation and carry the required GitHub CLI/tooling.

## Decision

Add the `gate` capability label to `gha-meta-1` and `gha-meta-2`, retaining
`meta` as an identity and rollback label. Both runners remain in GCP runner group
4, whose access is selected and public repositories are denied under ADR 0028.

This raises private merge-gate capacity from four to six runners without:

- adding machines;
- widening runner-group repository access;
- changing public workflow routing;
- changing workflow permissions, secrets, or review policy; or
- allowing ordinary bulk CI to target the two runners (they still lack the
  general `GCP` label).

## Consequences

- Private review gates can use the former meta capacity immediately.
- Public repositories continue on fixed hosted capacity and cannot select these
  runners through the group authorization boundary.
- The `meta` label remains available for operational identification and rollback
  but no supported workflow routes to it.
- If either machine lacks a capability needed by the current gate, remove only
  its `gate` label and investigate; do not widen workflow fallback labels.

## Live mutation and rollback

After this ADR merges, add `gate` through the organization runner-label API for
runner ids 18 (`gha-meta-1`) and 30 (`gha-meta-2`). Record the before/after
labels on issue #171.

Rollback removes `gate` from those two exact runner ids. Runner-group membership,
repository allowlists, and all other labels remain unchanged.

## 2026-08-01 amendment — the premises of this ADR no longer hold

Recorded because this page still asserts, as current fact, an admission boundary that is
not in force. A reader arriving here would conclude the opposite of the live state.

- **"Both runners remain in GCP runner group 4, whose access is selected and public
  repositories are denied under ADR 0028"** — group 4 is `visibility: all` with
  `allows_public_repositories: true` and zero selected members. Public repositories are
  *admitted*, deliberately, per
  [ADR 0041](../0041-shared-admission-hosted-and-self-hosted/README.md), which supersedes
  ADR 0028 decision 4.
- **"ADR 0028 later moved `.github` and every public-target gate to fixed GitHub-hosted
  capacity so public code cannot reach persistent runners"** — not in force. Every
  `Verjson` caller, including the public `.github`, routes to self-hosted.
- **`gha-meta-1` and `gha-meta-2` no longer exist.** The live fleet is six `gha-general-*`
  runners plus `hostinger` ([ADR 0040](../0040-runner-lanes-and-admission-axes/README.md)).
  The capacity change this ADR describes is therefore historical.

The decision itself is left as written — a decided ADR is not edited to reverse it. This
amendment marks which of its factual premises have since gone stale.
