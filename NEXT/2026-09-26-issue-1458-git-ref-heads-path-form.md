---
date: 2026-09-26
issue: 1458
impact: patch
title: renovate-changelog encodes the head branch as one path segment under git/ref/heads/
---
`scripts/renovate-changelog.py` now builds `repos/<repo>/git/ref/heads/<branch>` (and the matching `git/refs/heads/` update) with the branch percent-encoded in full (`renovate%2Fx`), the spelling `scripts/release-propose.py` already uses for the same endpoint and the shape ADR 0192's path rule requires. The renovate test fixtures pin the encoded form for both the read and the update.
