---
date: 2026-08-10
issue: 710
title: Identify authorization App mutation failures precisely
---

Bind the dedicated GitHub App token explicitly on every approval and check mutation, validate the minted App and installation identity before mutation, and preserve phase-specific GitHub response diagnostics so approval and check failures can no longer collapse into one ambiguous 403.
