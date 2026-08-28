---
date: 2026-08-28
issue: 1117
impact: patch
title: Diagnose interrupted secretless dependency acquisition
---

Fail the required build job before cache restore when secretless dependency acquisition
did not complete, naming the likely interrupted eligibility job and the safe rerun remedy.
Intentional Renovate stability deferrals remain green and continue to report their
required context.
