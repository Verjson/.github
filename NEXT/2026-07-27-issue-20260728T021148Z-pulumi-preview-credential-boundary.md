---
date: 2026-07-27
id: 20260728T021148Z
title: Separate Pulumi validation from trusted live-preview credentials
---

`pulumi-ci.yml` now runs caller-supplied install and validation commands in a
GitHub-hosted `contents: read` job with no package, Git, cloud, OIDC, or
repository-write credentials. A separate live-preview job receives its required
permissions and secrets only after successful validation and explicit
fail-closed admission for pushes or same-repository PRs; fork PRs, unknown
events, and missing cloud credentials stay on validation only. Both checkouts
disable credential persistence and all third-party actions are digest-pinned
(Verjson/.github#151; ADR 0027).
