---
date: 2026-08-06
issue: 31
title: The changelog check is now a required status check for contract adopters
---

The `changelog / validate` context is required on the default branch of the 23
repositories that carry the generated `changelog-validate.yml` caller, through a new
organization ruleset scoped by the `changelog-contract` repository property. The contract
was previously advisory: a branch that predated the caller could merge with no changelog run
recorded at all. Requiring the check does not require a PR to carry a fragment — that is a
separate decision about `check-pr`. Recorded in ADR 0061.
