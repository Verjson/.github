---
date: 2026-07-28
id: 20260728T021149Z
title: Close Pulumi validation runner and admission leaks
---

Pinned credential-free validation to the GitHub-hosted `ubuntu-24.04` image and
reduced preview admission inputs to boolean secret-presence flags. Callers can
no longer route validation commands onto a runner with ambient credentials, and
the admission job never receives raw cloud secret values (#151; ADR 0027).
