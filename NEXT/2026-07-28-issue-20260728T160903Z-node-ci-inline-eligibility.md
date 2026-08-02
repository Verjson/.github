---
date: 2026-07-28
id: 20260728T160903Z
title: node-ci eliminates its ci-eligibility self-pin
---

`node-ci` now inlines the co-located `ci-eligibility` action's shell block,
eliminating a manually-maintained remote self-pin from its transitive dependency
graph. The extraction suite requires exact parity between the reusable workflow
and composite-action copies and exercises defer, clean, fail-open, and dispatch
behavior. This avoids the self-update loop that Renovate maintenance would
create while preserving the `statuses: read` boundary and stability-days
semantics. Exact consumer examples advance to the planned `v2.1.1` patch release,
which is published only after this change merges. Fixes #164; see ADRs 0014 and
0023.
