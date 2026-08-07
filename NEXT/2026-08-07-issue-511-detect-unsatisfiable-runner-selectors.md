---
date: 2026-08-07
title: Detect queued jobs with unsatisfiable runner selectors
issue: 511
---

Add a report-only pass to the scheduled fleet watchdog that detects queued
self-hosted jobs whose full label set matches no online organization runner
admitted to the requesting repository. Reports identify the repository, run and
job, labels, queue age, and whether the cause is labels/offline capacity or a
runner-group admission boundary.

Compatible admitted runners count as satisfiable even when busy, so ordinary
capacity pressure is not reported as selector drift. The detector evaluates
selected groups, `visibility: all`, and the default group explicitly, inspects
queued jobs within both queued and in-progress runs, and returns undetermined on
unreadable or incomplete API evidence. It runs as an independent job, so its API
volume, timeout, or failure cannot consume or suppress the watchdog's existing
deadlock-cancellation budget. Bounded API timestamp skew is reported with age
zero rather than misclassified as unreadable state.
