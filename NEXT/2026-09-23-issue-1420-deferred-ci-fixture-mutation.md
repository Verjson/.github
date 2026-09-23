---
date: 2026-09-23
issue: 1420
title: Bind the deferred-CI regression fixture to its exact delta
impact: patch
---

The pre-ADR-0178 conformance fixture generator now validates and removes exactly
`jobs.deferred-ci` from a copied contract document. Independent structural-difference
assertions and paired wrong-field controls prevent a renamed, moved, or malformed job from
silently turning the historical counterexample into a passing but irrelevant fixture.
