# Org CI defers while renovate/stability-days is pending — 2026-07-24

New composite action `.github/actions/ci-eligibility` checks a PR head for a
pending `renovate/stability-days` status (the signal the merge gate already
`defer`s on) and outputs `should-run`. `node-ci.yml` gained an `eligibility` job
and gates `build-test` on it (`needs:` + `if: … == 'true'`), so every node-ci
consumer stops burning the CI suite on a Renovate PR that can't merge and
re-burning it on the inevitable rebase (casualty: toquorum#161 ran ~20 CI-min
while held). Fails OPEN on any uncertainty (API error / missing status → run) and
a `workflow_dispatch` always runs. Deferred jobs report `skipped` → the PR stays
BLOCKED until Renovate rebases on age-clear and `synchronize` re-fires CI for real
(self-healing, approved on #133). Pinned by `scripts/ci-gate/ci-eligibility.test.sh`,
wired into `actions-ci.yml`. ADR 0023. Hand-rolled CI adoption (toquorum,
catalog-*, viager-app) is default-pm's, tracked from #133. Refs #133, toquorum#161.
