---
date: 2026-09-01
issue: 1229
impact: minor
title: node-ci secretless acquisition covers nested manifests with per-manifest package and script authorization
---

`node-ci.yml`'s secretless mode hardcoded the root lockfile in every
acquisition, packaging, and install path, so a repository whose private
dependencies are not all reachable from `./package-lock.json` had no
credentialless way to obtain them at all. `Verjson/verjson-authn#252` is the
live case: `examples/catalog-google-login/` has its own manifest and lockfile
and depends on a private `@verjson/*` package, so its deliberately
credentialless job only passed on a warm self-hosted runner cache and failed
`E403 read_package` on a cold one. Giving that job a token would have put a
package-read credential in a job that runs untrusted PR-authored lifecycle
scripts — the exact regression this workflow exists to prevent.

New optional input `secretless-nested-manifests`, a JSON array of 1–8 objects
carrying exactly `path`, `approvedPackages`, and `scriptPlan`:

```yaml
      secretless-nested-manifests: |
        [{"path": "examples/catalog-google-login",
          "approvedPackages": ["@verjson/oidc-claims-middleware"],
          "scriptPlan": ["verify"]}]
```

Authorization is scoped to the declaring manifest: each lockfile's private
package set must equal that manifest's own `approvedPackages` exactly, so
neither the root nor any nested manifest inherits another's approvals in either
direction. Each `scriptPlan` is validated against — and executed with its
working directory set to — its own manifest, so a nested plan cannot reach a
root-only script. Declared paths are bounded relative segments whose resolved
location must sit inside the workspace, re-proved independently by the
credentialless job because a PR-authored symlink satisfies every syntactic rule.

The credentialless job still receives zero package-read credential. Nested blobs
join the same bounded, digest-verified transfer; the transfer manifest gains
`nested_manifests_sha256`, a digest over the ordered `path` + lockfile-digest
pairs, so a lockfile swapped after acquisition fails the binding check before
npm runs. Each manifest then installs from that one verified cache with
`--ignore-scripts` and no network credential. Nested support is npm-only and
rejects a pnpm caller before parsing any lockfile.

`node-ci-protected.yml` is regenerated and the identity pin repinned. Behavior
is covered by `scripts/ci-gate/node-ci-secretless-nested-manifests.test.sh`
(registered in the `platform` group), including cross-manifest smuggling
controls in both directions, aliased declarations resolving to one directory,
symlink escapes on both sides of the boundary, post-acquisition lockfile
tampering, and an end-to-end two-manifest transfer and install. Rationale is
recorded in [ADR 0157](../docs/decisions/0157-per-manifest-secretless-acquisition/README.md).
