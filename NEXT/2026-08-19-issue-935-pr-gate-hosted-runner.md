---
date: 2026-08-19
issue: 935
impact: patch
title: Default the generated pr-gate caller to a hosted, ephemeral runner
---

`scripts/gen-changelog-caller.sh pr-gate` emitted a `pull_request`-triggered job pinned to `[self-hosted, general]`. On that trigger `actions/checkout` resolves the pull request's own ref, and the job then executes PR-authored `scripts/changelog-contract.test.sh` from that checkout — on a persistent self-hosted runner, that is arbitrary code execution from any PR author, discovered when it blocked a real adopter's trust policy from accepting the caller at all. The default is now GitHub-hosted `ubuntu-24.04` (ephemeral, isolated per job), matching this repository's own convention for PR-triggered security-boundary jobs. Adopters with a genuinely isolated, ephemeral, per-job untrusted-PR lane can opt back into a self-hosted selector explicitly with the new `--untrusted-runner` flag.
