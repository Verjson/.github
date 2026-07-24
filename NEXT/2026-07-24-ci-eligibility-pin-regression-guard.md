# Regression guard for the ci-eligibility @main self-pin — 2026-07-24

Closes the coverage gap flagged in #139: the #138 fix (reference the co-located
`ci-eligibility` action `@main`, exclude it from Renovate digest pinning) had no
test asserting it, so a future Renovate re-pin could silently reintroduce the #135
"action not found" break. `node-workflow-pins.test.sh` now asserts three things:
node-ci's `ci-eligibility` ref is exactly `@main`; it is NOT digest-pinned (no
40-hex ref); and `renovate.json` carries the `pinDigests:false` exclusion for
`Verjson/.github` in node-ci.yml. Test-only; no behaviour change. Refs #135, #138, #139.
