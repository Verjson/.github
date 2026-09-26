---
date: 2026-09-26
id: 20260926T234500Z
impact: patch
title: Repin the authn required workflow to the hosted tool-cache tree fix (#1599)
---
`authn-type-surface-required.yml` now calls `node-ci-protected.yml@3f8fb4bae1bdf0ced0b821e1b4277523f72a93b9`, the merge of #1624, so the hosted protected type-surface lane for `verjson-authn` stops failing on `setup-node lexical PATH ancestry has unsafe ownership mode`. The ruleset script and its test carry the same pin.
