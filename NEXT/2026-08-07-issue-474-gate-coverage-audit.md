---
date: 2026-08-07
issue: 474
title: Add an ownership-bounded gate coverage audit
---

Add a dry-run-first fleet audit that reports every exact open pull request missing the current `gate` context and proposes a supported PR-associated retrigger.

The audit refuses mutation without both `--apply` and exact per-repository authority, never pushes or dispatches workflows, and fails closed on pagination, rate-limit, or metadata uncertainty. ADR 0058's corrected baseline is 14 of 97, with 12 non-transient gaps across six repositories; the issue remains open until a fresh audit reaches zero.

The first live dry-run of the shipped implementation on 2026-08-07 found 26 current gaps, 25 eligible for an ownership-routed retrigger and one excluded. No mutation was performed.
