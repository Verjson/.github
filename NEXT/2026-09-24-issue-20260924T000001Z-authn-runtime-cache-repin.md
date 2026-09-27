---
date: 2026-09-24
id: 20260924T000001Z
title: Repin authn required workflow after protected cache fix
impact: patch
---

Repin the generated authn required workflow and its ruleset renderer to the
merged canonical protected-CI commit that permits a missing optional runtime
cache while retaining strict validation when a cache is present.
