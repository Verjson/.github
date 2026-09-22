---
date: 2026-09-22
issue: 1541
impact: patch
title: Remove redundant branch reference guard
---
Removed the empty branch reference guard: the earlier empty-branch return and `set -e` already stop classification if URI encoding fails.
