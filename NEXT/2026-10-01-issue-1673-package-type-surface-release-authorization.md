---
date: 2026-10-01
issue: 1673
impact: patch
title: Standardize package type-surface release authorization
---

Package type-surface rulesets now have one organization-owned release-App policy with exact preimage/postimage auditing and scheduled conformance coverage.

The rollout preserves the type-surface gate, confines release credentials to the snapshot job, and requires the existing atomic release canary before package publication.
