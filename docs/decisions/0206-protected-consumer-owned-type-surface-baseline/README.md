# 0206 — Bind type-surface baselines to protected consumer declarations

- **Date:** 2026-09-23
- **Status:** Accepted
- **Issue:** [#1575](https://github.com/Verjson/.github/issues/1575)

## Context

The organization owns the required type-surface workflow, credential isolation, package authorization, fail-closed verifier, and evidence receipt. Released package versions change more frequently than the control plane. Embedding a baseline in the central workflow either makes every package release a control-plane change or leaves consumers comparing against a stale version.

## Decision

Each package repository owns one small JSON declaration on its protected default branch:

```json
{"package":"@verjson/example","version":"1.2.3","script":"test:type-surface-compatibility"}
```

The canonical reusable workflow resolves the pull request base commit once through the authenticated GitHub API and reads the declaration only at that exact commit. It never reads the pull request head, merge tree, workspace copy, fork, or a later floating default-branch value. A declaration change therefore takes effect only after it lands on protected `main`.

The verifier accepts only the exact declaration shape, a stable released semantic version, and the protected caller’s approved package script. The version must be authorized by `CI_SECRETLESS_PACKAGE_POLICY`. It resolves the exact package artifact through authenticated GitHub Packages and passes only verified exact-range evidence to the existing credentialless `node-ci` lane. The receipt binds repository, declaration path, base SHA, declaration digest, package, version, script, and registry integrity/tarball provenance. Any malformed, duplicate, unauthorized, unavailable, or tampered value fails closed.

## Consequences

Consumers advance one protected declaration when a released baseline changes; they do not manage a Git SHA or `latest`. Canonical CI remains the only owner of enforcement and credentials. New `@verjson/*` packages should follow `scripts/gen-type-surface-caller.sh` and `docs/type-surface-baseline.md`.
