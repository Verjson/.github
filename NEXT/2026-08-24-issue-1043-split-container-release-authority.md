---
date: 2026-08-24
issue: 1043
impact: major
title: Split container release Git and package authority
---

Container releases now mint the repository-bound Contents-only Release App token solely
for protected Git and GitHub Release writes, while ephemeral job tokens independently
authorize GHCR promotion and retention. Generated callers no longer require a release PAT.
