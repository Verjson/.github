# 0003 — Runner groups: GCP / GitHub (last resort) / manish

- **Date:** 2026-07-15
- **PR:** Verjson/.github#25 (this ADR; the change itself is org Actions settings via API)
- **Category:** org Actions runner groups / CI infrastructure (sensitive-class)

## Context

All self-hosted runners lived in the org's `Default` runner group, alongside
the implicit GitHub-hosted capability that group carries. Nothing distinguished
the Google Cloud pool from GitHub-hosted, and there was no clean way to say
"GitHub-hosted is last resort." Goal: keep every Verjson repo on self-hosted
runners (GCP primary, `manish` secondary) with GitHub-hosted reserved as a
fallback, and make the group names reflect that.

The `Default` group can be renamed (verified via API and reverted during
investigation). GitHub-hosted runners are always reached through the `default`
group; they are never listed as members, so once the self-hosted runners are
moved out, the renamed group represents GitHub-hosted only.

## Decision

Org Actions runner groups (`Verjson`), via REST API:

1. **Created `GCP`** (id 4), `visibility: all`, `allows_public_repositories:
   true`.
2. **Moved all 9 self-hosted runners into `GCP`:** the 8 GCE runners
   (`gha-runner-3..6`, `gha-gate-1..4`; each already carries a `GCP` label
   alongside `gce`) plus `gha-meta-1` (`meta`).
3. **Renamed `Default` (id 1) → `GitHub`.** It now holds zero self-hosted
   runners, so it is purely the GitHub-hosted last-resort access point. It
   remains `default: true` (that flag cannot move to a custom group).
4. **`manish` (id 3) unchanged**, and added a `manish` label to its `hostinger`
   runner so workflows can target it by `runs-on`.

Final state:

| Group | id | default | visibility | public | runners |
|---|---|---|---|---|---|
| GitHub | 1 | yes | all | yes | 0 |
| manish | 3 | no | all | no | 1 (`hostinger`) |
| GCP | 4 | no | all | yes | 9 (8 GCE + `meta`) |

## Consequences

- Every repo (incl. the public `.github` repo, whose gate targets the `meta`
  runner) keeps access: `GCP` is `visibility: all` + public-allowed, so moving
  runners out of `Default` broke no CI. `runs-on` matches on labels
  (`gce`/`GCP`/`gate`/`meta`/`manish`); group membership only governs access.
- GitHub-hosted is now an explicit, empty, last-resort group.
- **Operational caveat:** `GitHub` (id 1) is still `default: true`, so a newly
  registered self-hosted runner auto-lands there, not in `GCP`. New runners must
  be moved to `GCP` after registration (a custom group cannot be made default).
- Remaining follow-up (separate work): migrate the ~27 repos still running real
  CI on `ubuntu-latest` onto `[self-hosted, GCP]`, and convert the leaf repos to
  the reusable `notify-umbrella` workflow.
