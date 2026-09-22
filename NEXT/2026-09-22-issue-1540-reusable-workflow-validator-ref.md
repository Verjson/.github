---
date: 2026-09-22
issue: 1540
impact: patch
title: Gate re-arm on pinned App-key validation
---
Use the pinned App-key environment policy result for re-arm validation. This avoids a checkout at the caller's workflow SHA that may not exist in `Verjson/.github` and prevents review dispatch when the policy check fails.

Part of #1540
