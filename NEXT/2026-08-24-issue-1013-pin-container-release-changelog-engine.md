---
date: 2026-08-24
issue: 1013
impact: patch
title: Pin the container release changelog engine
---

Container releases now acquire and execute the changelog engine from the caller's exact
immutable canonical contract SHA, so a clean generated adopter no longer needs a local
copy of `scripts/changelog.py`.
