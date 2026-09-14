---
date: 2026-09-14
issue: 1324
title: Require a NEXT fragment for production source changes in check-pr
impact: minor
---

`changelog.py check-pr` required a NEXT fragment only when the diff touched a
dependency manifest or lockfile, so a change to production source code — the
reproduction in #1324 is `tools/subscriber-gateway/gateway.mjs` in
`Verjson/verjson-ci` — landed on `main` with nothing in the running log and
exit 0.

`check-pr` now also requires a new valid fragment when the diff changes
production source. "Production source" is a source-code suffix outside an
explicitly named exemption. The suffix set spans every language the
organization names — including `.mts` and `.cts`, the exact TypeScript stack
the `@verjson/*` packages ship, alongside `.cs .sql .tf .kt .swift .php .c
.cpp .h .vue .svelte .psm1` — so no org stack escapes the running log: `NEXT/`, `CHANGELOG/`, `docs/`, and tests
(`tests/`, `spec/`, `__tests__/`, `__mocks__/`, `test_*`, `*.test.*`,
`*_test.*`, `*.spec.*`). Exemptions are enumerated rather than inferred, so
widening one is a visible change.

Workflow definitions under `.github/workflows/` and `.github/actions/`, and
a repo-root `action.yml` — the published entrypoint of a composite or JS
action, which previously escaped the class entirely — are
**reported on stderr, not rejected**, when they change with no fragment. The
organization Renovate preset that auto-merges action-pin bumps lives in
`Verjson/renovate-config` and cannot be changed from here; rejecting them now
would stall every bot upgrade rather than document it. An audit of the last 250
first-parent commits on `Verjson/.github` `main` found 246 already satisfy the
new rule and all 4 exceptions are exactly those bot action-pin bumps.

Adopters pinned to an older contract SHA are unaffected until they re-pin.
