---
date: 2026-09-27
id: 20260927T020000Z
impact: minor
title: release-snapshot callers no longer assume a Node project (#1374)
---
`gen-changelog-caller.sh release-snapshot` callers run `setup-node`, `npm ci`, and version stamping only when a root `package.json` exists, and a repository without one must verify through an executable `scripts/release-verify.sh` or the release fails closed before the snapshot (#1206). Root `package.json` is the contract for "this is a Node project" in snapshot mode; a snapshot adopter with packages only in subdirectories should regenerate as `release-node` or commit a verify hook. Existing Node snapshot adopters are unaffected; regenerate at this commit to pick up the guards. This is the first half of giving `Verjson/.github` its own generated release caller (ADR 0191): the caller itself is regenerated at this commit's merge SHA in the follow-up so its provenance header names a commit whose generator produced it.
