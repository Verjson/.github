---
date: 2026-08-11
issue: 748
title: Require the authorization arm from its own property-scoped ruleset
---

Split the `workflows` rule out of `main-protection` into
`ai-authorization-arm-required`, selecting `gate-rearm.yml@main` and scoped by the
`verjson-core-checks: enforced` repository property. `main-protection` keeps
`deletion`, `non_fast_forward`, `required_linear_history`, and `pull_request` at
`~ALL`, unchanged.

This restores the organization merge gate for the 21 repositories that have
canonical deterministic CI without waiting on the 70 that do not, and without
weakening branch protection anywhere. Deterministic-CI coverage and App
credential reach are now required of armed repositories only, because a
repository the arm does not govern cannot have the arm as its only merge
precondition. See ADR 0094, which supersedes ADR 0091.
