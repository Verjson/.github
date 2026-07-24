# node-ci's ci-eligibility self-reference is @main, not a v1 digest — 2026-07-24

Fixes a live break from #134/#135. node-ci referenced its co-located
`ci-eligibility` action via the `v1` tag, and Renovate (`pinDigests: true` on
node-ci.yml) pinned it to `9f36163 # v1` (#135) — a commit predating the action,
so `uses: …/ci-eligibility@<that-sha>` was "action not found" on `main` for every
`@main` node-ci consumer (verjson-agents/authn/email/eslint-config + templates).
Root cause: the moving `v1` tag lags `main` until a release is manually cut, so
pinning a first-party self-reference from `v1` resolves to a pre-action commit.
Fix: reference `@main` (a branch tip always resolves to a commit with the action)
and add a `renovate.json` rule excluding this self-reference from digest pinning
(first-party, no supply-chain reason to pin). ADR 0023 updated. Refs #133, #134, #135.
