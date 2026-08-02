---
date: 2026-07-29
id: 20260729T134417Z
title: node-ci routes on isolated-pool admission, not owner
---

`node-ci.yml` targeted `[self-hosted, isolated, linux, x64]` for every
`github.repository_owner == 'Verjson'` caller after #175, but org runner group
`isolated` (id 6) is `visibility: selected` and admits only `.github`,
`verjson-cli`, `verjson-cli-cloud`, and `verjson-cli-project-init`. Every other
consumer's `ci / eligibility` job queued forever — no check run ever reported, so
the merge gate waited out its timeout and failed (live on Verjson/verjson-authn#87
and #88). Both `runs-on` expressions now test `github.repository` against the
isolated-pool allowlist and fall back to `ubuntu-24.04` for anyone else; the
`runner` input remains the per-caller override. The org runner-group allowlist is
unchanged — pool admission stays the org admin's call (#182, ADR 0031).

`scripts/ci-gate/runner-routing-policy.test.sh` now awk-extracts the real
`runs-on:` expression from both jobs and evaluates it, asserting the whole routing
table plus byte-identical parity between `eligibility` and `build-test`, so the
two copies cannot drift. `node-release.yml`, `notify-umbrella.yml`, `helm-ci.yml`,
`ui-ci.yml`, and `pulumi-ci.yml` still carry the owner-wide form and the same hang
— tracked in #185, not fixed in this hotfix. That gap is live, not latent:
`verjson-authn` calls `node-release.yml@main`, so its release job still queues.
