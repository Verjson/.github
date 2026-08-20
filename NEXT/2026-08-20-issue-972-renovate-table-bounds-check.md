---
date: 2026-08-20
issue: 972
impact: patch
title: Fail closed instead of crashing on a Renovate body ending in a header row
---

`table_rows` indexed `lines[index + 1]` to read a candidate table's separator
row without checking that line existed, so a pull-request body whose final
line was itself a header row (`| Update | Change |` with nothing after)
raised an unhandled `IndexError` instead of the intended `AutomationError`.
Added the missing bounds check.
