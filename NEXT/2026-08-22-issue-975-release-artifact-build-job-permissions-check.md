---
date: 2026-08-22
issue: 975
impact: patch
title: 'fix(security): verify the release-artifact build job's permissions and secret exposure'
---

An independent review of `release-artifact` (#975, merged via #1004) found that
the generated `contract-test` checked the `build` job's `needs:`, `if:`, `ref:`,
hook executability, and artifact-upload pin, but never its `permissions:` block
or whether its steps reference a `secrets.*` context. A hand-edited consumer
caller escalating that job's `permissions` from `contents: read` to
`contents: write`, or adding `RELEASE_APP_PRIVATE_KEY` to a build step's `env:`,
passed the generated `scripts/changelog-contract.test.sh` with exit 0 — the
contract-test exists specifically to reject exactly this kind of generated/actual
divergence. `RELEASE_APP_PRIVATE_KEY` mints the App token with
main-protection-bypass power (ADR 0099); leaking it into a job that runs
adopter-owned `scripts/release-build.sh` — potentially third-party build tooling
— on caller-chosen runners would be a severe privilege escalation.

The generator's own template already emits the correct least-privilege shape
(`contents: read`, only `RELEASE_VERSION` as env); only the contract-test's
verification of that shape was missing. `contract-test` mode now asserts the
extracted `build_job`'s `permissions:` block is exactly `contents: read`, and
that no `secrets.*` context appears anywhere in the job (a blanket ban rather
than a per-secret denylist, since `scripts/release-build.sh` has no legitimate
need for any secret today).
