---
date: 2026-09-10
issue: 1271
impact: patch
title: Attribute grouped Docker image variants independently
---

Renovate attribution now distinguishes complete package/version transitions, so grouped Alpine and Bookworm updates for the same image produce one fragment containing both changes. Exact duplicate rows still fail, including equivalent linked and bare package cells. Regression coverage uses the real infra #229 table; ADR 0104 records the preserved trust boundary.
