---
date: 2026-09-23
issue: 1575
impact: minor
title: Bind protected consumer type-surface baselines
---

Canonical CI now resolves each consumer's type-surface declaration at the
exact pull-request base commit, validates the released package artifact against
the protected package policy, runs the approved compatibility script
credentiallessly, and emits a tamper-evident evidence receipt.

The consumer repositories own only the released semantic version and approved
script in a minimal protected declaration; they do not own enforcement, package
credentials, or a Git SHA.
