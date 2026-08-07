---
date: 2026-08-07
id: 20260807T140000Z
refs: 455
title: Node publication consumes the contract-selected release
summary: Reintroduce node-release.yml as a publish-only consumer of the exact version and tag created by the dispatched changelog contract.
---

The generated Node release caller now verifies the source tree, snapshots and
tags the selected version through the changelog contract, then calls the
publish-only `node-release.yml` at the same immutable contract pin.

Publication rejects malformed or absent tags and missing immutable release
notes. Private dependency installation uses the caller-supplied read token;
package and GitHub release publication use the repository-scoped token.
Reruns prove an existing package's identity and integrity before resuming
GitHub Release publication. Semantic-release and `.releaserc.json` are no
longer part of this path.
