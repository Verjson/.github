---
date: 2026-08-25
issue: 1088
impact: minor
title: Graduate packages to v1 only when consumer evidence justifies it
---

Add the canonical `v1.0.0` readiness contract and replace the mandatory organization-wide release wave with package-scoped graduation based on consumer value, readiness, bounded migration, and durable ownership.

ADR 0159 supersedes ADR 0137 without changing versions already published. Passing the bar makes a package eligible rather than forcing every pre-v1 package into one wave; repository owners retain their evidence and decide independently whether the stability promise is justified.

Below `1.0.0`, the minor position carries the breaking-change role, so a guardrail published as a new `0.x` minor does not reach consumers on an older caret range. The readiness bar remains necessary whenever a package elects to make the binding SemVer promise that begins at `1.0.0`.
