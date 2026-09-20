---
date: 2026-09-20
issue: 1518
impact: patch
title: Match title hold markers as whole phrases
---

AI review workflows now recognize `DO NOT MERGE` as a whole phrase in PR titles. Permissionless event classification, receipt re-arming, and both merge gates use the same word boundaries, so longer unrelated words no longer trigger title holds.
