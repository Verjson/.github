---
date: 2026-08-30
issue: 1187
title: Bind secretless Node acquisition to trusted PR workflow code
impact: patch
---

Generate the cli-projects organization required workflow from a strict canonical
configuration. Validate the live pull-request repository, number, head, merge commit,
merge ref, and exact generated push-only consumer caller before the immutable Node CI
contract receives package-read authority. Fail rollout closed until that caller is
byte-identical at one protected `main` commit, and bind every ruleset write to that
unchanged commit with verified rollback on drift. Candidate dependency acquisition remains
non-executing, both Node lanes execute without credentials, and the protected
package-surface verifier runs only after both succeed.
