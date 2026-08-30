---
date: 2026-08-30
issue: 1193
title: Align the cli-projects verifier Node floor
impact: patch
---

Derive the protected cli-projects package-surface engine requirement from the
strict required-workflow Node configuration. The verifier now accepts the v1
`>=24.19.0` floor used by its Node floor lane and rejects the retired
`>=20.20.2` contract, with a synchronization regression covering both surfaces.
