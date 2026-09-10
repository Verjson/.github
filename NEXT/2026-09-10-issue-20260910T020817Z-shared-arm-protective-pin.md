---
date: 2026-09-10
id: 20260910T020817Z
impact: patch
title: Require a protective pin before shared App-key contract adoption
---

Correct the shared arm rollout record: ruleset 20722935 follows main without an
immutable SHA. Require a reviewed one-field freeze to the current protected
workflow before this contract merges, preserving all existing selectors and
bypasses. Keep the live freeze receipt separate from the later cohort-wide
environment-key cutover and broad-secret removal.
