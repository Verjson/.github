---
date: 2026-08-07
issue: 561
title: Force local paths for generated package publication
---

Generated multi-package Node releases now pass explicit local paths to npm, preventing a configured directory name from resolving and attesting an unrelated registry package.

The root remains `.`, validated secondary directories become `./<dir>`, and a real-npm regression proves both artifacts pack locally while the configured registry is unreachable.
