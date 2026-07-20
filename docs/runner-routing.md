# Runner routing & labels

Where verJSON CI jobs run, and how to pick a `runs-on` label. This is the
operational reference for the runner-group structure decided in
[ADR 0003](decisions/0003-runner-groups-gcp-github-manish/README.md); read that
for the *why* of the groups, this for the *how* of day-to-day routing.

## TL;DR

- **Default to `[self-hosted, GCP]`** for ordinary CI (build/test/lint/release).
- **Docker/kind/buildx jobs must pin `[self-hosted, docker]`** — the general GCP
  pool has **no Docker socket**.
- **Labels describe *capability*, not just provider.** `GCP` ≡ `gce` = the 8 GCE
  VMs with the ambient GCE toolchain (`gh`, git, node baseline). A runner joins
  `GCP`/`gce` **only** if it carries that toolchain; a non-GCE box gets a
  purpose/identity label instead (`manish`, `docker`, `meta`). This invariant was
  restored in ADR 0011 after the non-GCE `hostinger` runner, mislabeled `GCP`, broke
  the gate's `gh` call (#52) — it is now `manish`-only.
- Self-hosted runners have **no ambient Node** and a **persistent shared
  `~/.gitconfig`** — use `actions/setup-node` and idempotent git config, or just
  the [`setup-verjson-node`](../.github/actions/setup-verjson-node/README.md)
  composite action.

## Labels

| Label      | Runners                                            | Group    | Use for                                                                                                   |
| ---------- | -------------------------------------------------- | -------- | --------------------------------------------------------------------------------------------------------- |
| `GCP`      | `gha-runner-3..6`, `gha-gate-1..4` (8 GCE VMs)     | `GCP`    | **Canonical general-pool label.** Ordinary CI: build / test / lint, releases, `notify-umbrella`. GCE image → ambient `gh`/git/node. |
| `gce`      | the same 8 GCE VMs (dual-labeled `GCP` + `gce`)    | `GCP`    | **Clean alias of `GCP`** — identical runners (invariant restored in ADR 0011). Deprecated for new work; reconcile `gce` → `GCP` opportunistically. |
| `gate`     | `gha-gate-1..4` (a subset of the GCE VMs)          | `GCP`    | **All** org gate jobs — `freshness`, `classify`, `ai-review`, `ai-merge` (non-`.github`). Dedicated GCE subset: has ambient `gh` and keeps gate load off general CI. |
| `meta`     | `gha-meta-1` (+ `gha-meta-2` pending, [#70](https://github.com/Verjson/.github/issues/70)) | `GCP`    | The `Verjson/.github` repo's **own** gate jobs — a dedicated lane so pipeline-fix PRs never queue behind bulk/other-repo CI (#14). Registered `meta`-only so bulk CI can never occupy it. Must be **redundant** (≥2 `meta`-only runners — [ADR 0016](decisions/0016-self-gate-runner-redundancy/README.md)); one runner is a SPOF. See the caveat below. |
| `docker`   | `gha-docker-1`                                     | `GCP` †  | Docker / kind / buildx / testcontainers — anything needing the Docker daemon. **Required**, not optional (see below). |
| `manish`   | `hostinger` runner                                 | `manish` | Secondary / overflow pool on a **non-GCE image** (no ambient `gh`; Node via `setup-node`). Target explicitly by label; jobs must self-provision tools. ‡ |
| _(none)_   | GitHub-hosted                                      | `GitHub` | **Last resort only.** Reserved fallback; not used for real CI.                                             |

† `gha-docker-1` post-dates [ADR 0003](decisions/0003-runner-groups-gcp-github-manish/README.md)
(which enumerates only the original 9 runners), so its runner-group membership
isn't recorded there; the `GCP` group is the assumed home. Confirm against the
live org runner-group settings if it matters for access.

‡ `hostinger` previously also carried `GCP`, so `[self-hosted, GCP]` jobs could land
on it and fail for want of ambient `gh` (`gh: command not found`, #52). Its `GCP`
label was removed ([ADR 0011](decisions/0011-hostinger-runner-labels-capability-accurate/README.md)),
so it now serves only its explicit `manish` consumers. To promote it back to general
`GCP`/`gce` overflow, provision `gh` + git on the box (toolchain parity) first — a
one-time on-box step owned by the runner-topology owner.

## Routing rules

- **Ordinary Node/library CI, releases, submodule notifications** →
  `[self-hosted, GCP]`. The [`node-ci`](../.github/workflows/node-ci.yml) /
  [`node-release`](../.github/workflows/node-release.yml) /
  [`notify-umbrella`](../.github/workflows/notify-umbrella.yml) reusable
  workflows already default here; callers only override `runner` to reach a
  different pool (e.g. `manish`), never to fall back to `ubuntu-latest`.
- **Docker / kind / buildx / anything touching the Docker daemon** →
  `[self-hosted, docker]` (`gha-docker-1`). The general `GCP` pool has **no
  Docker socket**, so these jobs fail there. `gha-docker-1` is currently the only
  `docker`-labeled runner, so such jobs serialize on it (capacity/redundancy is
  tracked in issue #31 item 6).
- **The org AI gate** (`ai-review-merge.yml`): **all** gate jobs — `freshness`,
  `classify`, `ai-review`, `ai-merge` — run on `gate`. They call `gh`, so they need
  the dedicated GCE subset (which has ambient `gh` and excludes the `hostinger`
  overflow); routing `freshness`/`classify` to `GCP` let them land on `hostinger`
  and fail (#52). When the target repo **is** `Verjson/.github` itself, they run on
  `meta` instead (the self-gate lane) — a dedicated lane so pipeline-fix PRs never
  queue behind bulk/other-repo gate work (#14). That lane must stay **redundant**
  (≥2 `meta`-only runners); a single runner is a SPOF that leaves `.github` PRs
  un-gated if it drops. Provisioning the second runner (`gha-meta-2`, GCE,
  `meta`-only) is tracked by [#70](https://github.com/Verjson/.github/issues/70)
  ([ADR 0016](decisions/0016-self-gate-runner-redundancy/README.md)); no workflow
  change is needed — `runs-on: [self-hosted, meta]` picks it up on registration.
- **Secondary / overflow** → `[self-hosted, manish]`.

## Constraints every self-hosted job must respect

These bit us during the hosted→self-hosted migration
(`Verjson/verjson-cli-cloud#59`):

1. **No ambient Node.** GitHub-hosted images ship Node; the self-hosted runners
   don't. Every job needing Node must run `actions/setup-node` (or the
   `setup-verjson-node` composite action) — never assume `node`/`npm` is on PATH.
2. **Persistent, shared `~/.gitconfig`.** Runners are long-lived containers, so
   the home gitconfig carries state between jobs. A plain `git config` set of a
   multi-valued key (e.g. `url.*.insteadOf`) collides with a prior job's entry
   (`cannot overwrite multiple values`). Use `--unset-all` then `--add`, or the
   `setup-verjson-node` action which does it idempotently.
3. **The current `meta` runner cannot resolve private composite actions.**
   `gha-meta-1` is not a GCE box, so it
   fails to resolve `uses: Verjson/verjson-observability@…` at job setup, and
   `uses:` resolution isn't guarded by `continue-on-error` — so a private-action
   step breaks the whole job on `meta`. Keep private-action steps off `meta`
   jobs, or gate them by `github.repository != 'Verjson/.github'`. (This is why
   the gate's OTLP-emit step was **removed from the `meta` lane** — see the
   `NOTE: OTLP emit temporarily removed` comment in
   [`ai-review-merge.yml`](../.github/workflows/ai-review-merge.yml). The
   exporter is *separately* dormant until an OTLP endpoint is provisioned, per
   [`docs/ci-telemetry.md`](ci-telemetry.md) — two distinct reasons, not one.)
   Provisioning `gha-meta-2` as a **GCE** runner ([ADR 0016](decisions/0016-self-gate-runner-redundancy/README.md))
   removes this limitation for the lane, since GCE runners resolve private
   composite actions.

## Drift & migration

- **Canonical general label is `GCP`.** `gce` is a legacy alias on the same
  runners; normalize `gce` → `GCP` opportunistically. Known remaining `gce`
  users at time of writing (per issue #31 item 4): `verjson-cli`, `verjson-authz`,
  `AiB`. This repo's own gate `classify` job was normalized in the PR that added
  this doc.
- **~27 repos still run real CI on `ubuntu-latest`** and are migrating to
  `[self-hosted, GCP]` (ADR 0003 follow-up).
- **New runners auto-land in the wrong group.** The `GitHub` group (id 1) is
  still `default: true` (a custom group can't be made default), so a newly
  registered self-hosted runner lands in `GitHub`, not `GCP`, and must be moved
  after registration (ADR 0003).
