---
date: 2026-08-08
issue: 655
title: Receipt-bound AI review provider and budget policies
---

- Allow organization variables to select a primary Anthropic policy and an explicit re-review policy.
- Add one-call, tool-free OpenAI `gpt-5.6-luna` review with a conservative hard dollar ceiling and receipt-bound long-context pricing evidence.
- Embed the bounded PR metadata/diff in tool-free requests, strictly validate completed response evidence, and require a currently authorized maintainer for explicit paid re-review.
- Keep trusted developer instructions role-separated from JSON-encoded, PR-controlled review data so diff content cannot redefine the review policy.
