---
date: 2026-08-08
issue: 624
title: Isolate Actions CI contracts from runner bootstrap labels
---

Clears the routed runner's ambient `RUNNER_LABELS` value at the shell-contract
boundary, so extracted reusable-workflow fixtures observe only inputs they set
explicitly and behave the same on developer and self-hosted environments.
