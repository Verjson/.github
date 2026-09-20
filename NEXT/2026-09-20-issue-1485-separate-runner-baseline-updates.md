---
date: 2026-09-20
issue: 1485
impact: patch
title: Keep hosted runner baseline updates out of Renovate
---

Renovate no longer updates `github-runner` dependencies or groups the `ubuntu` runner selector with action digest updates. The reviewed organization runner baseline stays under coordinated policy control; individual runner image migrations require a complete rollout instead of a partial workflow edit.
