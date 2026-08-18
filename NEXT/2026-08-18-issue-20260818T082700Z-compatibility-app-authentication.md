---
date: 2026-08-18
id: 20260818T082700Z
refs: 699
title: Authenticate compatibility policy reads with the dedicated App
---

Use the compatibility App client ID for observer authentication and mint its
least-privilege token before the grouping planner checks out the private policy
repository on the trusted lane. Both observe-first workflows now fail closed on one documented
credential boundary instead of relying on a repository-scoped workflow token. Each
mint explicitly requests only the read permissions its job needs.
