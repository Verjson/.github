---
date: 2026-08-08
issue: 660
title: Accept documented Responses reasoning items
impact: patch
---

Allow documented completed Responses API `reasoning` output items before or
after exactly one completed assistant message. Unknown output types, tool calls,
multiple messages, malformed or incomplete reasoning, refusal/error evidence,
wrong models, and usage beyond the hard preflight envelope still fail closed.
