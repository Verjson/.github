---
date: 2026-08-25
issue: 1015
impact: patch
title: Attribute bare-name Renovate image digest updates
---

Accept Renovate's bounded bare package-name form so Docker image digest updates receive their canonical changelog fragment.

The parser continues to preserve linked package attribution and rejects malformed, ambiguous, marked-up, injected, or oversized package cells. Invalid package and change cells now identify the failing field.
