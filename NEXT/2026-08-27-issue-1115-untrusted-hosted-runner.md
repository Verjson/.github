---
date: 2026-08-27
issue: 1115
title: Route untrusted CI aliases to ephemeral hosted runners
impact: patch
---

Strengthen runner admission so the six canonical and historical untrusted
selectors reconcile as one configuration and accept hosted routing only as the
exact `ubuntu-24.04` label. This prepares the human-gated organization-variable
cut without changing trusted, fallback, privileged, or default runner routing;
the live cut and exact-head consumer canary remain separate rollout actions.
