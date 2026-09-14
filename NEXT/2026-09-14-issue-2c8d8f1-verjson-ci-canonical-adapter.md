---
date: 2026-09-14
id: 2c8d8f1
title: Package-backed portable CI adapter
impact: major
---

`Verjson/.github` now contains the reviewed thin facade for the
`Verjson/verjson-ci` portable CI package. The facade pins package source to an
immutable commit, requires a complete-release OCI image digest, and documents
separate GitHub and GitLab identity/credential boundaries. Existing GitHub
`node-ci.yml` remains the shadow/canary fallback; this does not claim a live
production cutover before signed release identities and authenticated
deployment evidence are available.
