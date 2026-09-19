---
date: 2026-09-19
issue: 1507
impact: patch
title: Route terminal-hold labels through the merge gate
---

Adding a terminal-hold label now disables native auto-merge before the gate exits. The event allowlist accepts normalized `hold` and `do-not-merge` labels and tests the lowercase `hold` case without dispatching a paid review.
