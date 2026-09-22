---
date: 2026-09-22
issue: 1545
impact: patch
title: Allow isolated hosted lanes in reusable runner inputs
---

The hosted-selector policy now permits the exact `CI_RUNNER_ISOLATED` lane expression in reusable runner inputs and continues rejecting unreviewed routing expressions. `Verjson/verjson-cli#265` adopts the supported expression for its isolated compatibility lane.
