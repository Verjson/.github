---
date: 2026-08-16
issue: 869
impact: patch
title: Restrict container candidate credentials to required trust paths
---
Generate secretless, read-only pull-request validation for container candidates that
declare no private Node packages, and reserve write and OIDC permissions for trusted
publication events.

The canonical contract tests now exercise public-only and private-package caller
generation and reject widened event permissions or unnecessary package-token routing.
ADR 0078 records the restored trust boundary.
