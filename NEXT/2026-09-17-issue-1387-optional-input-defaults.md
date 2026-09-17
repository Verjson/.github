---
date: 2026-09-17
issue: 1387
title: An omitted optional input takes the value the runtime would supply
impact: patch
---

`bind_inputs` gave an optional `workflow_call` input with no declared default
the empty string for every type but boolean. That is right for a string and
wrong for a number, which GitHub supplies as `0`: bound as `''`, an unsupplied
numeric input compares unequal to every number a guard could test it against,
and the guard is modelled false for a reason the contract never expressed.

Unreachable today — both `node-ci.yml` and `node-ci-protected.yml` declare a
default for every optional input — which is the argument for fixing it rather
than noting it. It is the value the harness would model an adopter as running
with the moment one input loses its default, and nothing would be watching then.

A type this harness has no runtime value for now raises `AdopterContractMismatch`
instead of silently taking the string branch. Guessing is how a model stops
asserting anything while continuing to look thorough.

Covered by a synthetic contract/caller pair, since the shipped contracts cannot
reach the path. Control-tested: with the previous behavior restored, both new
assertions fail.

Follow-up from the AI review of #1386.
