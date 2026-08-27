---
date: 2026-08-27
issue: 1149
impact: patch
title: Authorize exact secretless call subsets
---
Treat the protected secretless package policy as a repository-wide authorization superset while every reusable call retains an exact, lock-bound package and scope subset.

Preserve compatibility-range authorization, unused-approval rejection, credential isolation, and existing fail-closed paths. Record the security boundary in ADR 0149 and mutation-test the multi-call case exposed by `verjson-authn#251`.
