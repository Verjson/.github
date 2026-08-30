---
date: 2026-08-30
issue: 1159
impact: patch
title: Resolve hosted-selector policy from its checkout
---
Derive canonical workflow authority from the hosted-selector policy script's checked-in repository layout instead of the caller's working directory, while failing closed for moved or symlinked policy copies and preserving consumer enforcement.
