---
date: 2026-09-27
id: 20260927T010000Z
impact: patch
title: node-ci-protected provisions the hosted sandbox for every lane that runs the protected plan (#1423)
---
On GitHub-hosted runners `node-ci-protected.yml` now provisions the trusted compatibility sandbox whenever a lane will run the protected script plan or the compatibility lanes, not only when the caller declares a type surface or compatibility ranges. The protected script plan requires the bubblewrap boundary unconditionally, so callers without those inputs (verjson-cli-projects' package-surface lanes) failed closed with `verified bubblewrap namespace boundary is unavailable` the moment their required workflow was activated. Regenerated from `scripts/gen-node-ci-protected.py`; ADR 0209 carries a dated amendment.
