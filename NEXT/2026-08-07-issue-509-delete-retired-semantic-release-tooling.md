---
date: 2026-08-07
title: Delete the retired semantic-release tooling and audit surface
issue: 509
---

Remove the semantic-release package and lockfile, Node floor guard, programmatic runner,
audit wrapper and allowlist, and the scheduled persistent-cache probe. The publish-only
`node-release.yml` contract remains covered, as do the live workflow and composite-action
pinning and cache controls.

CI no longer installs or audits a dependency no release executes. Renovate and workflow
triggers no longer maintain the deleted surfaces, and ADR 0060 records completion of the
follow-up it required.
