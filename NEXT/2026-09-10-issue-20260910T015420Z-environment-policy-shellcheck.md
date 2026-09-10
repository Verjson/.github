---
date: 2026-09-10
id: 20260910T015420Z
impact: patch
title: Distinguish environment policy records from workflow inputs
---

Rename the policy response variable so ShellCheck no longer mistakes the
uppercase workflow environment selector for a misspelled local variable.
Keep the exact main-only policy checks and credential boundary unchanged.
