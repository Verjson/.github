---
date: 2026-09-14
id: 20260914T070454Z
impact: patch
refs: 1274
title: Refresh the reviewed Node-floor baseline to the activated producer bindings
---

The reviewed `core-checks-node` baseline snapshot behind the opt-in Node-floor
preparation still recorded the pre-activation projection of organization ruleset
`20515817`, whose three required contexts carried no producer App binding. ADR 0173's
authorized rollout bound `ci / build-test`, `ci / eligibility` and `changelog-contract`
to GitHub Actions App `15368` at 2026-09-10T15:24:16.455Z, so every `render` and
`dry-run` against live policy failed closed on baseline drift. The snapshot now records
the verified postimage; the delta is exactly those three `integration_id` additions, with
identity, selectors, enforcement, branch conditions and bypass actors byte-for-byte
unchanged. Preparation stays read-only and still emits a disabled candidate.

Part of #1274.
