# 0203 — Bind type-surface baselines to protected consumer declarations

- **Date:** 2026-09-23
- **Status:** Accepted
- **Issue:** [#1575](https://github.com/Verjson/.github/issues/1575)

## Context

The organization owns the required type-surface workflow, credential isolation,
package authorization, fail-closed verifier, and evidence receipt. Released
package versions change more frequently than that control plane. Embedding a
baseline in a central workflow either makes every package release a control
plane change or leaves consumers comparing against a stale version.

## Decision

The package repository owns one small JSON declaration on its protected default
branch:

```json
{"package":"@verjson/example","version":"1.2.3","script":"test:type-surface-compatibility"}
```

The canonical reusable workflow resolves the pull request base commit once via
the authenticated GitHub API, then reads that declaration only at that exact
commit. It never reads the pull request head, merge tree, workspace copy, fork,
or a later floating default-branch value. Therefore a declaration change takes
effect only after it lands on protected `main`.

The verifier accepts only the exact declaration shape, a stable released
semantic version, the protected caller's package and script, and a version
authorized by `CI_SECRETLESS_PACKAGE_POLICY`. It resolves the exact package
artifact through authenticated GitHub Packages and passes only the verified
exact range to the existing credentialless `node-ci` lane. The receipt binds
the repository, declaration path, base SHA, declaration digest, package,
version, script, and registry integrity/tarball provenance. Any malformed,
duplicate, unauthorized, unavailable, or tampered value fails closed.

## Consequences

Consumers update one protected declaration when a released baseline advances;
they do not manage a Git SHA or `latest`. Canonical CI remains the only owner
of enforcement and credentials. New `@verjson/*` packages should use
`scripts/gen-type-surface-caller.sh` and the adoption procedure in
`docs/type-surface-baseline.md`.
