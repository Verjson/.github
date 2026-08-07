# Reusable-workflow versioning & release

How the org reusable workflows in `Verjson/.github/.github/workflows/*.yml`
(`helm-ci`, `pulumi-ci`, `ui-ci`, `node-ci`, `node-release`, `notify-umbrella`, …)
are versioned, how caller repos should pin them, and how a release is cut. This is
the operational reference for the decision recorded in
[ADR 0014](decisions/0014-reusable-workflow-versioning/README.md); read that for
the *why*, this for the *how*.

## TL;DR

- **Exact/reproducible:** pin the current release, `@v2.2.0`, never `@main`.
  `uses: Verjson/.github/.github/workflows/helm-ci.yml@v2.2.0`
- **Compatible auto-updates:** opt into `@v2`, the moving major tag. It points at
  the newest backward-compatible `v2.x.y` release, so fixes and additive inputs
  arrive without a caller edit. It is deliberately mutable.
- A **breaking change** to any reusable means a new major (`v3` + `v3.0.0`).
  Callers stay on v2 until they opt in; Renovate can open the v2 → v3 bump.
- Releases are **human-triggered**: cut a GitHub Release for `vX.Y.Z`, and the
  [`tag-major`](../.github/workflows/tag-major.yml) workflow re-points the `vX`
  moving tag to that release commit. Nothing auto-mutates tags on a plain push.

## Why pin (not `@main`)

Every consumer repo references these workflows by a *mutable* ref. A push to `main`
here reaches **every caller at once** — the exact risk called out in
[ADR 0010](decisions/0010-platform-templates-consume-reusable-workflows/README.md)'s
Consequences ("a breaking change to a reusable can reach every template at once").
Pinning to a tag turns that org-wide blast radius into a per-repo, Renovate-driven,
reviewable bump.

An exact `vX.Y.Z` tag is the SemVer audit point consumers can use directly.
The moving `vX` alias trades immutability for compatible updates. A full commit
SHA is the strictest pin and is required for dependencies nested inside these
shared workflows, so an exact-pinned caller cannot execute mutable transitive
code.

## Versioning scheme

Semantic versioning of the `.github` repo as a whole (all reusables share one version
line — they ship together):

| Bump      | When                                                             | Example         |
| --------- | --------------------------------------------------------------- | --------------- |
| **major** | breaking change to any reusable's inputs/behavior/contract      | `v1.4.2 → v2.0.0` |
| **minor** | new reusable, or a **new optional input** (existing callers unaffected) | `v1.4.2 → v1.5.0` |
| **patch** | bug fix, internal refactor, runner/pin bump inside a reusable   | `v1.4.2 → v1.4.3` |

Tags maintained:

- **`vX.Y.Z`** — immutable, one per release. The audit point.
- **`vX`** — moving major, re-pointed to the newest `vX.*` on each release. **This is
  an explicit auto-update option, not an immutable pin.**

Callers on `@vX` need no edit for a minor/patch; exact-release and digest callers
take those updates through reviewed Renovate PRs. Every caller opts into a major.

## How callers pin

```yaml
# .github/workflows/ci.yml in a consumer repo
jobs:
  helm:
    uses: Verjson/.github/.github/workflows/helm-ci.yml@v2.2.0 # exact SemVer release
    with:
      release-name: my-chart
```

Use `@v2` instead when compatible releases should arrive automatically:

```yaml
jobs:
  helm:
    uses: Verjson/.github/.github/workflows/helm-ci.yml@v2 # moving major
```

### Renovate's role

The org already runs Renovate (`config:recommended`, which enables the
`github-actions` manager). With callers on an exact release or digest it can
propose reviewed compatible updates. With callers on `@v2` it will:

- **Track the major** — when `v3` is published, open one bump PR per repo
  (`@v2 → @v3`), so each team reviews the breaking change on its own schedule
  instead of being broken in place.
- Optionally **pin-to-digest** (`…/helm-ci.yml@<sha> # v2`) for repos that want the
  stricter exact-pin posture — Renovate then bumps the SHA and keeps the `# v2`
  comment. See "moving-major vs exact-pin" in ADR 0014.

Caller edits are owned by each consumer repository; publishing a release here
does not rewrite their workflow files.

## Cutting a release

1. Land the change on `main` (green CI, gate-reviewed as usual).
2. Decide the bump (major/minor/patch) from the table above.
3. **Publish a GitHub Release** with tag `vX.Y.Z` targeting the merge commit:

   ```bash
   # from an up-to-date main
   git switch main
   git pull --ff-only origin main
   verified_sha="$(git rev-parse --verify HEAD^{commit})"
   # Run the release verification against "$verified_sha" before publishing.
   gh release create vX.Y.Z --repo Verjson/.github \
     --target "$verified_sha" --generate-notes \
     --title "vX.Y.Z"
   ```

   Keep `verified_sha` unchanged between verification and publication. If
   `main` advances meanwhile, the release still targets the exact commit that
   was verified rather than the newer branch tip.

4. The [`tag-major`](../.github/workflows/tag-major.yml) workflow fires on
   `release: published`, validates the tag is `vX.Y.Z`, and force-updates the `vX`
   moving tag to the release commit. Callers on `@v2` pick it up on their next run.

### One-time bootstrap (historical)

The `v1.0.0` + `v1` tags were the one-time manual bootstrap described by ADR
0014. They already exist; do not run these commands again. They remain here as
the recovery/audit record for how a new version line was initialized:

```bash
# pick the commit that becomes v1.0.0 (usually current main)
git tag -a v1.0.0 -m "v1.0.0 — first pinned release of org reusable workflows"
git tag -a v1     -m "v1 — moving major, tracks the latest v1.x.y"
git push origin v1.0.0 v1
# equivalently, publish a GitHub Release for v1.0.0 and let tag-major create v1
```

After the bootstrap, every subsequent release follows the "Cutting a release" flow
above and `tag-major` maintains `vX` automatically.
