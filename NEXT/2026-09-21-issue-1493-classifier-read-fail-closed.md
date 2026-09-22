---
date: 2026-09-21
issue: 1493
impact: major
title: Fail closed when repository workflow classification reads fail
---

The classifier now distinguishes repositories with no workflows from unreadable or truncated GitHub tree responses, so uncertain repository state is not silently classified as having no CI. Regression coverage includes empty inventories, metadata and tree read failures, truncated trees, and workflow content failures.
