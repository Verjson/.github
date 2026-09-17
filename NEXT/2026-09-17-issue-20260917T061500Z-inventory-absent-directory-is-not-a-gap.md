---
id: 20260917T061500Z
title: The fleet inventory no longer reports an absent workflows directory as a gap
impact: patch
---

`scripts/fleet-contract-inventory.py` counted every repository whose
`.github/workflows` listing 404s as `unreachable`. Fourteen fleet repositories
answer that way — eleven have no workflows directory and three have no commits
at all — so the sweep reported fourteen gaps it did not have and exited nonzero
for a benign reason.

Absence is now **confirmed rather than inferred**. A 404 is not self-explanatory:
GitHub answers 404 wherever admitting existence would leak, the repository
enumeration is one snapshot taken before hundreds of later calls, and repository
metadata and Contents are different permissions — so a repository deleted, made
private, transferred, or dropped from an App installation mid-sweep answers
exactly like one that simply has no workflows. `gh_listing()` therefore requires
a positive observation: `repos/{repo}` must still read, and then either the
repository root lists or `commits` reports 409. Anything else stays
`unreachable`.

Confirmed absences are named and counted in the report as
`absent_directories`, but deliberately excluded from the exit predicate: they
are completed observations, not holes in the sweep. `workflows()` keeps its
contract that `{}` never means "the listing call failed".

Part of #1364
