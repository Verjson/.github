---
date: 2026-09-17
issue: 1370
title: Name the fleet sweep's capped workflow listings instead of under-reporting them
impact: patch
---

The AI-review follow-up on `scripts/fleet-contract-inventory.py` read the
workflow listing as paginated and silently truncated past 30 entries. It is
neither. `repos/{repo}/contents/.github/workflows` returns the whole directory
in one unpaginated response — 49 entries for this repository's own workflows,
with no `Link` header — so `--paginate` would change nothing and there is no
page to follow.

What the endpoint does do is stop at 1,000 entries, and it says so nowhere in
the response. A capped listing is byte-indistinguishable from a complete one, so
a sweep that reports completeness would quietly claim to have inventoried a
directory it had only partly read. That is the same fail-open shape as an empty
listing standing in for a failed one, which `workflows()` already refuses.

The sweep now counts the listing against that cap and names the repository as a
gap when it is reached, which also makes the run exit non-zero rather than
reporting a clean sweep. No adopter is near 1,000 workflow files today; the
point is that the day one is, the tool says so instead of under-reporting drift.

Closes #1370
