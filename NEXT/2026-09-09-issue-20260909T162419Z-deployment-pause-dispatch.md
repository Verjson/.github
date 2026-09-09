---
date: 2026-09-09
id: 20260909T162419Z
impact: patch
title: Clarify how to pause before a worker deployment
---

The deployment runbook now instructs operators to preserve the dry-run plan and withhold the mutating dispatch when pausing before deployment, matching ADR 0144's production environment without a required environment reviewer.
