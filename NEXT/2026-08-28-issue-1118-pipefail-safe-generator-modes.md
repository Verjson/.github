---
date: 2026-08-28
issue: 1118
impact: patch
title: Make pinned generator mode checks deterministic
---

Read the pinned changelog generator once before checking its advertised modes, eliminating pipefail races while preserving distinct unreadable-source and missing-mode failures.

Behavioral mutations prove that a removed mode remains a semantic failure and an unreadable pinned object still fails at the source-read boundary.
