---
date: 2026-09-01
issue: 1209
impact: patch
title: Define the measured GitLab CI migration contract
---

Define a phased, reversible migration of economically justified CI workloads from GitHub Actions to GitLab, preserving exact-head checks, trust boundaries, parity evidence, and a measured total-cost objective.

ADR 0161 and the migration runbook keep stateful GitLab CE maintenance separate from blue/green GitLab Runner operations and from #629's GitHub runner fleet. The decision introduces no shared controller and authorizes no live CI, secret, infrastructure, or spending mutation.
