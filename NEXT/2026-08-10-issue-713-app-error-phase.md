---
date: 2026-08-10
issue: 713
title: Preserve App mutation phase diagnostics
---

Write dedicated-App failure annotations to stderr so command substitution cannot swallow the rejected operation, while retaining sanitized GitHub request diagnostics and request IDs without exposing the installation token.
