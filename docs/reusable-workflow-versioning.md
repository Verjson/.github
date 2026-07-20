# Reusable-workflow versioning & release

How the org reusable workflows in `Verjson/.github/.github/workflows/*.yml`
(`helm-ci`, `pulumi-ci`, `ui-ci`, `node-ci`, `node-release`, `notify-umbrella`, …)
are versioned, how caller repos should pin them, and how a release is cut. This is
the operational reference for the decision recorded in
[ADR 0014](decisions/0014-reusable-workflow-versioning/README.md); read that for
the *why*, this for the *how*.

## TL;DR

- **Callers pin `@v1`, never `@main`.**
  `uses: Verjson/.github/.github/workflows/helm-ci.yml@v1`
- `v1` is a **moving major tag**: it always points at the newest backward-compatible
  release of the `v1.x.y` line. Bug fixes and additive inputs reach callers by
  re-pointing `v1` — no caller edit needed.
- A **breaking change** to any reusable means a new major (`v2` + `v2.0.0`). Callers
  stay on `@v1` until they opt in; Renovate opens the `@v1 → @v2` bump PR per repo.
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
  what callers pin.**

A minor/patch never requires a caller edit; a major does (opt-in via Renovate).

## How callers pin

```yaml
# .github/workflows/ci.yml in a consumer repo
jobs:
  helm:
    uses: Verjson/.github/.github/workflows/helm-ci.yml@v1   # ← moving major, not @main
    with:
      release-name: my-chart
```

### Renovate's role

The org already runs Renovate (`config:recommended`, which enables the
`github-actions` manager). With callers on `@v1` it will:

- **Track the major** — when `v2` is published, open one bump PR per repo
  (`@v1 → @v2`), so each team reviews the breaking change on its own schedule
  instead of being broken in place.
- Optionally **pin-to-digest** (`…/helm-ci.yml@<sha> # v1`) for repos that want the
  stricter exact-pin posture — Renovate then bumps the SHA and keeps the `# v1`
  comment. See "moving-major vs exact-pin" in ADR 0014; moving-major `@v1` is the
  org default, digest-pin is the opt-in hardening.

No caller edits are in scope for *this* repo — retagging existing `@main` callers
(`catalog-helm`, `viager-infra`, `catalog-ui`, and the platform templates from
ADR 0010) is follow-up that Renovate/consumers own once `v1` exists.

## Cutting a release

1. Land the change on `main` (green CI, gate-reviewed as usual).
2. Decide the bump (major/minor/patch) from the table above.
3. **Publish a GitHub Release** with tag `vX.Y.Z` targeting the merge commit:

   ```bash
   # from an up-to-date main
   gh release create v1.2.0 --repo Verjson/.github \
     --target main --generate-notes \
     --title "v1.2.0"
   ```

4. The [`tag-major`](../.github/workflows/tag-major.yml) workflow fires on
   `release: published`, validates the tag is `vX.Y.Z`, and force-updates the `vX`
   moving tag to the release commit. Callers on `@v1` pick it up on their next run.

### One-time bootstrap (manual, human-run — deferred)

The very first `v1.0.0` + `v1` tags are **not** created by CI (creating tags from
automation is deliberately avoided for the bootstrap; see ADR 0014 §Consequences).
An org maintainer runs, once, against a chosen `main` commit:

```bash
# pick the commit that becomes v1.0.0 (usually current main)
git tag -a v1.0.0 -m "v1.0.0 — first pinned release of org reusable workflows"
git tag -a v1     -m "v1 — moving major, tracks the latest v1.x.y"
git push origin v1.0.0 v1
# equivalently, publish a GitHub Release for v1.0.0 and let tag-major create v1
```

After the bootstrap, every subsequent release follows the "Cutting a release" flow
above and `tag-major` maintains `vX` automatically.
