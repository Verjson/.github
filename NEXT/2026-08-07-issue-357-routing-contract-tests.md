---
date: 2026-08-07
issue: 357
title: Bind merge-gate routing tests to each job and target
---

Semantically evaluate the exact `preflight`, `gate`, and `dispatch-merge` runner routes for public, private, unresolved, and external targets, and reject visibility lookups that query anything but the target repository’s `.private` field.

Mutation fixtures now prove that each job’s polarity is independently protected and that dispatcher-repository lookups cannot masquerade as target visibility.
