---
date: 2026-09-24
issue: 1602
impact: patch
title: Cover Renovate comparator ranges unioned with carets
---

Add regression coverage proving the Renovate changelog parser accepts a spaced
comparator range unioned with caret ranges, such as
`>=0.2.2 <0.4.0 || ^1.0.0 || ^0.4.0`, on either or both sides of a change.

The #1602 failure reproduces only at the consumer's stale contract pin
`4fb46916`, whose table parser rejected every escaped `\|` before the #1178 fix
(#1179) landed. Current `main` already parses the shape, so no parser change is
needed; the affected consumer must regenerate its caller at a current contract SHA.
