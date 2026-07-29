# node-release routes on isolated-pool admission, not owner — 2026-07-29

`node-release.yml` kept the owner-wide `github.repository_owner == 'Verjson'`
isolated route that #184 removed from `node-ci.yml`, so every Verjson repo
outside runner group 6's four-repo allowlist emitted a release job GitHub can
never assign. Verjson/verjson-authn run 30450460243 sat `queued` from 12:10:01Z
with `runner: ""` — the release for merged PR #86, whose OTP code-store fix
therefore sat on `main` while the published version stayed at 0.21.0.

A release hang is the invisible kind: no PR, no check run, no gate timeout to
report it. The only symptom is a version that never appears. The `release` job
now carries the byte-identical allowlist expression from `node-ci.yml`, so a
non-admitted repo gets a job that reports instead of one that queues forever
(#192, ADR 0031 amendment). The org runner-group allowlist is unchanged — pool
admission stays the org admin's call.

`scripts/ci-gate/runner-routing-policy.test.sh` now evaluates the routing table
for all three policy jobs (`node-ci` `eligibility`/`build-test`, `node-release`
`release`) and enforces byte equality **across files**. node-ci-only parity is
exactly what let these two drift for a day.

Hosted runners are billing-blocked org-wide (#189), so a non-admitted repo now
fails its release fast instead of hanging. That is a signal where there was
none, but it does not publish anything: verjson-authn still needs restored
Actions billing or admission to runner group 6, both org-admin calls.
`notify-umbrella.yml`, `helm-ci.yml`, `ui-ci.yml`, and `pulumi-ci.yml` still
carry the owner-wide form (#185).
