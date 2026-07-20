# 0014 — Version & pin the org reusable workflows (moving major tag)

- **Date:** 2026-07-20
- **Issue:** Verjson/.github#31 (item 5 — reusables referenced via mutable `@main`)
- **PR:** feat/reusable-workflow-versioning
- **Category:** CI architecture / supply-chain (release & pinning of shared CI —
  affects every consumer's CI at once; the mutable-ref risk itself is the concern)
- **Relationship:** resolves the deferred pinning item flagged in
  [ADR 0010](../0010-platform-templates-consume-reusable-workflows/README.md) §Consequences.

## Context

The org reusable workflows in `Verjson/.github/.github/workflows/*.yml`
(`helm-ci`, `pulumi-ci`, `ui-ci`, `node-ci`, `node-release`, `notify-umbrella`) are
consumed by other repos via `uses: Verjson/.github/.github/workflows/<lane>.yml@main`
— a **mutable** ref. A single push to `main` here re-defines CI for **every consumer
simultaneously**: `catalog-helm` (helm), `viager-infra` (pulumi), `catalog-ui` (ui),
and every rendered platform via the `verjson-{helm,infra,ui}-template` submodules
(ADR 0010). ADR 0010 accepted this coupling explicitly and deferred the fix to
#31 item 5 ("a breaking change to a reusable can reach every template at once —
mitigated by the extract-tests that gate reusable changes"). Extract-tests reduce
the chance of shipping a break; they do not bound its blast radius. Only a pinned,
per-repo, reviewable ref does that.

## Decision

1. **Version `.github` as a whole with SemVer** (all reusables ship on one version
   line): major = breaking change to any reusable's contract, minor = new reusable
   or new *optional* input, patch = bug fix / internal / pin bump.
2. **Maintain a moving major tag `vX` plus immutable `vX.Y.Z` releases.** `vX` is
   re-pointed to the newest `vX.*` on each release; `vX.Y.Z` is the immutable audit
   point.
3. **Callers pin `@v1`** (the moving major), *not* `@main`. Minor/patch releases
   reach them with no caller edit; a new major (`v2`) is opt-in per repo.
4. **Releases are human-triggered.** A maintainer publishes a GitHub Release for
   `vX.Y.Z`; the new `tag-major.yml` workflow (`on: release: published`,
   `contents: write`, tag-shape-validated) force-updates `vX` to that commit.
   Nothing mutates tags on a plain push.
5. **The initial `v1.0.0` + `v1` tags are a one-time manual org action, not created
   by this PR** — the exact `git tag`/`gh release` commands are documented in
   [docs/reusable-workflow-versioning.md](../../reusable-workflow-versioning.md).
6. **Renovate drives adoption and bumps.** Callers on `@v1` get a per-repo
   `@v1 → @v2` PR when a major ships; repos wanting stricter posture can digest-pin
   (`@<sha> # v1`) and let Renovate bump the SHA.

### Moving-major (`@v1`) vs exact-pin (`@vX.Y.Z` / `@<sha>`) — and why moving-major

| | Moving-major `@v1` (chosen default) | Exact-pin `@vX.Y.Z` or digest |
| --- | --- | --- |
| Patch/security fix reaches callers | automatically, no PR | only after a Renovate PR merges in each repo |
| Renovate PR volume | low (majors only) | high (every patch, every repo) |
| Supply-chain immutability | tag is mutable by the release job | fully immutable (esp. digest) |
| Reverting a bad release org-wide | re-point `v1` back (one action) | revert N caller PRs |

**Recommendation: moving-major `@v1` as the org default.** It gives the property we
actually want — fixes propagate without N per-repo PRs, and a bad release is undone
by re-pointing one tag — while still converting the `@main` blast radius into a
tag-gated, opt-in-per-major boundary. Exact/digest pinning stays available as
opt-in hardening for repos with a stricter supply-chain posture (documented), so we
are not choosing *against* immutability, only defaulting to the lower-friction tier.

## Consequences

- A push to `main` no longer reaches consumers; only cutting a release does, and a
  release is a deliberate human act. The org-wide-break risk from ADR 0010 is closed.
- **Migration path for existing `@main` callers** (follow-up, owned by
  consumers/Renovate — out of scope for this PR): once `v1` exists, each of
  `catalog-helm`, `viager-infra`, `catalog-ui`, and the `verjson-*-template`
  submodules flips `@main → @v1`. This is a caller-repo edit; ADR 0010 already
  established those callers, so the flip rides Renovate rather than a manual sweep.
- **Tag creation is deferred, deliberately.** This PR ships the scheme, the doc, and
  the release automation, but does **not** create `v1.0.0`/`v1` — creating the first
  release tags is a one-time org action (a maintainer runs the documented commands or
  publishes the `v1.0.0` Release). Automating the *bootstrap* tag creation was ruled
  out: it is an irreversible-ish, one-shot act better done by a human, and the steady
  state is covered by `tag-major.yml`.
- The `tag-major.yml` job force-pushes a tag (`git push --force refs/tags/vX`). This
  is intentional and bounded: it only touches the `vX` moving tag, only on a
  human-published `vX.Y.Z` release, and immutable `vX.Y.Z` tags are never rewritten.
- Because all reusables share one version line, a breaking change to *one* reusable
  bumps the major for *all* — a caller on an unrelated lane sees a `v2` Renovate PR
  that is a no-op for it. Acceptable at this repo count; if lanes diverge sharply,
  a future ADR can split version lines per lane.

### Effective change (sensitive hunk: release automation — `.github/workflows/tag-major.yml`)

New workflow; the security-relevant surface is the trigger, the token scope, and the
force-tag. Full file in the PR.

```diff
+on:
+  release:
+    types: [published]          # human-triggered only — never on push
+permissions:
+  contents: write               # least privilege: just enough to move the tag
+jobs:
+  retag-major:
+    steps:
+      - run: |
+          # shape-gate: only vX.Y.Z releases re-point a major
+          if [[ ! "$FULL_TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then exit 0; fi
+          MAJOR="${FULL_TAG%%.*}"
+          git tag -f "$MAJOR" "$FULL_TAG"
+          git push --force origin "refs/tags/$MAJOR"   # only the moving vX tag
```
