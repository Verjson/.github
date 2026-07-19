# Runner routing & labels

Where verJSON CI jobs run, and how to pick a `runs-on` label. This is the
operational reference for the runner-group structure decided in
[ADR 0003](decisions/0003-runner-groups-gcp-github-manish/README.md); read that
for the *why* of the groups, this for the *how* of day-to-day routing.

## TL;DR

- **Default to `[self-hosted, GCP]`** for ordinary CI (build/test/lint/release).
- **Docker/kind/buildx jobs must pin `[self-hosted, docker]`** — the general GCP
  pool has **no Docker socket**.
- **`GCP` is a *superset*, not a clean alias of `gce`.** The 8 GCE VMs carry both
  `gce` and `GCP`, but the `manish` overflow runner (`hostinger`) also carries
  `GCP` (without `gce`) and runs a **different image with no ambient `gh`/Node**.
  So a job that needs the GCE image's ambient tooling (e.g. the gate's `gh` calls)
  must **not** use `[self-hosted, GCP]` — it can land on `hostinger` and fail with
  `command not found`. Use `gce` (GCE VMs only) or a dedicated subset like `gate`.
- Self-hosted runners have **no ambient Node** and a **persistent shared
  `~/.gitconfig`** — use `actions/setup-node` and idempotent git config, or just
  the [`setup-verjson-node`](../.github/actions/setup-verjson-node/README.md)
  composite action.

## Labels

| Label      | Runners                                            | Group    | Use for                                                                                                   |
| ---------- | -------------------------------------------------- | -------- | --------------------------------------------------------------------------------------------------------- |
| `GCP`      | `gha-runner-3..6`, `gha-gate-1..4` **and `hostinger`** | `GCP` | **General-pool label — but a *superset* (see below).** Ordinary CI that self-provisions its tools (build / test / lint via `setup-node`, releases, `notify-umbrella`). **Not** for jobs needing ambient GCE tooling like `gh` — `hostinger` carries this label too. |
| `gce`      | the 8 GCE VMs only (`gha-runner-3..6`, `gha-gate-1..4`) | `GCP` | The GCE VMs **excluding** `hostinger`. Use when a job needs the GCE image's ambient tooling (`gh`, etc.) but isn't gate work. Not a clean alias of `GCP`. |
| `gate`     | `gha-gate-1..4` (a subset of the GCE VMs)          | `GCP`    | **All** org gate jobs — `freshness`, `classify`, `ai-review`, `ai-merge` (non-`.github`). Dedicated GCE subset: has ambient `gh`, excludes the `hostinger` overflow, and keeps gate load off general CI. |
| `meta`     | `gha-meta-1`                                       | `GCP`    | The `Verjson/.github` repo's **own** gate jobs — keeps the gate from deadlocking while reviewing itself. See the caveat below. |
| `docker`   | `gha-docker-1`                                     | `GCP` †  | Docker / kind / buildx / testcontainers — anything needing the Docker daemon. **Required**, not optional (see below). |
| `manish`   | `hostinger` runner (**also mislabeled `GCP`**)     | `manish` | Secondary / overflow pool on a non-GCE image (no ambient `gh`/Node). Target explicitly by label. ‡        |
| _(none)_   | GitHub-hosted                                      | `GitHub` | **Last resort only.** Reserved fallback; not used for real CI.                                             |

† `gha-docker-1` post-dates [ADR 0003](decisions/0003-runner-groups-gcp-github-manish/README.md)
(which enumerates only the original 9 runners), so its runner-group membership
isn't recorded there; the `GCP` group is the assumed home. Confirm against the
live org runner-group settings if it matters for access.

‡ `hostinger` carries **both** `manish` and `GCP`, so `[self-hosted, GCP]` jobs
can be scheduled onto it — but it runs a non-GCE image without ambient `gh`/Node,
which broke the gate's `classify` step (`gh: command not found`, #52). Dropping
`GCP` from `hostinger` (or provisioning `gh` on it) is the deeper fix, owned by the
runner-topology owner. Until then, gh/tool-dependent jobs avoid `GCP`.

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
  `meta` instead (the self-gate lane).
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
3. **`meta` runner cannot resolve private composite actions.** `gha-meta-1`
   fails to resolve `uses: Verjson/verjson-observability@…` at job setup, and
   `uses:` resolution isn't guarded by `continue-on-error` — so a private-action
   step breaks the whole job on `meta`. Keep private-action steps off `meta`
   jobs, or gate them by `github.repository != 'Verjson/.github'`. (This is why
   the gate's OTLP-emit step was **removed from the `meta` lane** — see the
   `NOTE: OTLP emit temporarily removed` comment in
   [`ai-review-merge.yml`](../.github/workflows/ai-review-merge.yml). The
   exporter is *separately* dormant until an OTLP endpoint is provisioned, per
   [`docs/ci-telemetry.md`](ci-telemetry.md) — two distinct reasons, not one.)

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
