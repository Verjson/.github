---
date: 2026-09-14
id: 20260914T090000Z
title: Enumerate every App private key binding so an unconfined one fails CI
impact: patch
---

Part of [#1285](https://github.com/Verjson/.github/issues/1285).

The App-key environment contract confines the release, merge and AI review keys, but
its CI gate proved that contract against a hand-written list of six workflows. Four
other App private keys are bound in the same workflow directory, and two of them —
`RENOVATE_COMPATIBILITY_APP_PRIVATE_KEY` and `DEPENDENCY_SUPERSESSION_APP_PRIVATE_KEY` —
declare no environment at all while sitting at organization visibility `all`. That is
exactly the exposure #1285 describes: a non-fork ref can read the key, because a branch
copy of the workflow simply omits the `environment:` line.

`config/app-key-roles.json` now declares every App private key a canonical workflow
binds, with its confinement kind and the intended disposition of its broad organization
copy. `scripts/ci-gate/app-key-environment.test.py` enumerates `.github/workflows`
instead of a fixed list and fails when the declaration and the directory disagree in
either direction, so a new App-key binding cannot be added without stating how it is
confined. `scripts/app-key-environment-audit.py` reports broad copies of every declared
key rather than only the three canonical roles, so a partial migration can no longer
read as compliant.

This changes no workflow's runtime behavior. The two unconfined bindings stay as they
are: binding an environment before the operator provisions it with an exact main-only
deployment-branch policy would create an unprotected environment and assert a
confinement that does not exist. They are declared `unconfined` and tracked here.
