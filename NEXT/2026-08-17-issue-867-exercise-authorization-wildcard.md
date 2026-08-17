---
date: 2026-08-17
issue: 867
impact: patch
title: Exercise authorization wildcard with distinct outcomes
---
Complete-authorization tests now exercise several distinct unknown AI-review outcomes, preventing an exact-token special case from masking a regression in the wildcard neutral human fallback.
