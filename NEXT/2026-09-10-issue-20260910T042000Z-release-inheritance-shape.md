---
date: 2026-09-10
id: 20260910T042000Z
impact: patch
title: Bind the release caller shape check to inherited environment context
---

Update the independent release caller shape validator to require the ADR 0171 inherited context together with release-app, and reject a mutation removing inheritance. Preserve publication ordering, immutable pins and the separate explicit node publication token grant.
