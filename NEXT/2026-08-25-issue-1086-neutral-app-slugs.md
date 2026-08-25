---
date: 2026-08-25
issue: 1086
title: Fail AI authorization slug drift closed without stranded checks
impact: patch
---

Record the canonical CI Apps' organization-neutral live identities and make the AI
authorization arm reject token/App slug drift before creating a check. If GitHub reports
an inconsistent identity after creation, the arm completes that check as failure before
exiting.
