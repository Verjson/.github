---
date: 2026-08-07
issue: 524
title: Require dependency updates to add a changelog fragment
---

Canonical pull-request validation now requires a new valid `NEXT/` fragment when supported dependency manifests or lockfiles change, including bot-authored updates.

The generated contract covers Node, Python, Go, Cargo, and Terraform dependency boundaries, rejects reuse of unrelated fragments, and fails closed on malformed revision input, unblocking `Verjson/verjson-upload#45`.
