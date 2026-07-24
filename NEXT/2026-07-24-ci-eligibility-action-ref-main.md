# node-ci references ci-eligibility@main, not @v1 — 2026-07-24

Follow-up to #133/#134. node-ci referenced the co-located `ci-eligibility` action
at `@v1`, but the moving major tag lags `main` until a release is cut, so `@v1`
did not contain the just-merged action. Since node-ci is consumed `@main` across
the org (verjson-agents/authn/email/eslint-config + templates), every such
consumer's `eligibility` job would have failed "action not found" on its next PR
(a red check that can stall the gate's CI-green wait). Repinned the action to
`@main` — it is co-located with node-ci and consumed only by it, so `@main` always
resolves and moves in lockstep. SHA-pinned consumers on a pre-eligibility ref are
unaffected. ADR 0023 updated. Refs #133.
