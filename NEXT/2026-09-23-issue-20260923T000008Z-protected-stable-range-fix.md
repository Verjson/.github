---
date: 2026-09-23
id: 20260923T000008Z
title: Accept stable versions in protected baseline acquisition
impact: patch
---

The protected workflow generator now keeps stable semantic-version validation
at the same level as its explicit prerelease branch. Generated consumers can
therefore acquire an authorized released baseline such as `3.0.0` or `0.11.1`;
the new regression test prevents stable declarations from being rejected as if
they required prerelease authorization.
