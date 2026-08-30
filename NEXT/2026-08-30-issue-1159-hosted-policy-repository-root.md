---
date: 2026-08-30
issue: 1159
impact: patch
title: Resolve hosted-selector policy from its checkout
---
Derive canonical workflow authority from the hosted-selector policy script's Git-verified, tracked checkout layout instead of the caller's working directory, while failing closed for fake repository markers, moved or symlinked policy copies, and preserving consumer enforcement.
