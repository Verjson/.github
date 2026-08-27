---
date: 2026-08-27
id: 20260827T052017Z
title: Correct the #1115 attended untrusted-runner cutover order
impact: patch
---

Correct #1115 so the five historical untrusted runner aliases move before
canonical `CI_LANE_UNTRUSTED`, and contract-test that the documented sequence
contains all six aliases exactly once with the canonical selector last. This
changes only the future human-gated rollout procedure; no organization variable
changed.
