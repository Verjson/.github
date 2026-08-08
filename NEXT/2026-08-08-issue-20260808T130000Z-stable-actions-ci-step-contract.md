---
date: 2026-08-08
id: 20260808T130000Z
title: Keep actions-ci grouping contract stable as setup steps evolve
---

The grouping contract now locates the named group runner step instead of assuming its
ordinal position, so adding bounded setup steps does not invalidate an unrelated CI
topology assertion.
