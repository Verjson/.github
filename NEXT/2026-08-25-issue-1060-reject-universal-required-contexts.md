---
date: 2026-08-25
issue: 1060
impact: patch
title: Reject retired universal required-check declarations
---

Fail the required-check audit at contract validation when a declaration
reintroduces the retired `universal_contexts` key, instead of silently ignoring
an authorization context excluded by ADR 0128.
