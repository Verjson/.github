---
date: 2026-09-21
issue: 1493
impact: major
title: Fail closed when repository workflow classification reads fail
---

The repository stack classifier now surfaces workflow inventory, fetch, and decode failures instead of silently classifying an unreadable repository as having no CI. Regression tests cover both API read boundaries.
