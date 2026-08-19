---
date: 2026-08-19
issue: 925
title: Accept Renovate's default source-link suffix in changelog attribution
---

`scripts/renovate-changelog.py`'s `PACKAGE` regex anchored immediately after the Package cell's first `[name](url)` link, but Renovate appends a ` ([source](…))` suffix by default whenever a package's `sourceUrl` differs from its homepage — not an opt-in presentation. Every such row (`vitest`, `@types/node`, and any package sharing that shape) failed `renovate-changelog: Renovate update table contains an unsupported package or change cell`, which meant no `NEXT/` fragment was ever written and the canonical contract's own required check then blocked the PR permanently. `PACKAGE` now accepts zero or more trailing ` ([label](url))` groups after the primary link.
