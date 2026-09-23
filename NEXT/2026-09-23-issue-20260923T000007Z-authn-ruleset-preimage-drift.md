---
date: 2026-09-23
id: 20260923T000007Z
title: Record the retired authn ruleset preimage
impact: patch
---

The canonical authn ruleset contract now records the already-disabled retired
repository ruleset preimage. This keeps the protected workflow rollout
fail-closed against the live control-plane state instead of treating a known
retirement as an apply-time surprise.
