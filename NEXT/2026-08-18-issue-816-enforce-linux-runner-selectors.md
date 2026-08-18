---
date: 2026-08-18
issue: 816
title: Enforce Linux runner selector policy in consumers
---

The required actionlint workflow now rejects literal Linux hosted-runner selectors in Verjson consumer workflows, including matrix and reusable-workflow inputs, while preserving reviewed lane expressions.
