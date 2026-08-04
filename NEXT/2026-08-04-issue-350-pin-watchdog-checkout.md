---
date: 2026-08-04
issue: 350
title: Pin privileged watchdog code to a reviewed revision
---

Pin the fleet watchdog checkout to a full default-branch commit SHA so a manual
dispatch ref cannot select code that receives `ORG_ADMIN_TOKEN`. A wired
contract test locks the checkout, command, input, and token-ordering boundaries;
ADR 0049 records the immediate mitigation and its residual secret-scope limits.
