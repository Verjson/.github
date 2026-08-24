---
date: 2026-08-24
issue: 731
impact: patch
title: Separate generated-contract conformance from merge authorization
---

Stop the staged generated-changelog ruleset audit from requiring the obsolete `gate` authorization context while preserving fail-closed `changelog-contract` validation.

ADR 0128 aligns #731 with the dedicated authorization-arm ruleset introduced by ADR 0094. The live ruleset remains unchanged and activation remains blocked until all selected consumers conform.
