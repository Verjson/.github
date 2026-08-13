---
date: 2026-08-12
issue: 752
title: Validate consumer npm config before auxiliary checkout
---

Reject consumer-controlled `.npmrc` files before materializing the policy-bound auxiliary checkout, so a trusted auxiliary repository's root `.npmrc` cannot trip the consumer guard or affect authenticated npm acquisition.
