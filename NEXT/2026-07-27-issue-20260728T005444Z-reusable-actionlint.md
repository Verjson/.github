---
date: 2026-07-27
id: 20260728T005444Z
title: Expose actionlint as a governed reusable workflow
---

Add `workflow_call` to the existing actionlint workflow while preserving its
local triggers, GCP default, pinned actionlint version, and checksum verification.
Consumers can choose only the governed GCP or `ubuntu-24.04` route, pin the call
by full commit SHA, and retain ownership of path filters and required-check
policy. Full-SHA nested Actions plus structural and real invalid-workflow tests
close #153; runner and required-check topology is recorded in ADR 0026.
