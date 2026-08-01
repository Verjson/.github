---
date: 2026-08-01
issue: 266
title: Resolve reconciler runner groups by name, and only when a lane selects them
---

The daily runner-admission reconciler pinned `UNTRUSTED_GROUP_ID=6`. Group 6
(`isolated`) and group 7 (`docker-builders`) were deleted on 2026-07-31, leaving the
organization with groups 1 (`GitHub`), 3 (`manish`), and 4 (`GCP`), so the fetch 404ed
and the job exited 2 on every run. It stayed fail-closed and never reported a dirty
organization as clean, but it reported nothing at all — the monitor went dark at the
moment its subject changed.

The pinned id was not the whole defect. Both lanes currently select `general`
(`VERJSON_RUNNER_UNTRUSTED = ["self-hosted","general"]`), so nothing routed to
`isolated`: the reconciler died fetching a group no decision depended on. Groups now
resolve by name against the live listing — `GENERAL_GROUP_NAME` and
`UNTRUSTED_GROUP_NAME`, both overridable — and only for lanes that actually select them.
A selected group that no longer exists still exits 2, now naming the group and the groups
that do exist, instead of printing a bare request URL. The listing is read as streamed
NDJSON and slurped so pagination cannot truncate it (cf. #260).

Evidence: run
[30683258273](https://github.com/Verjson/.github/actions/runs/30683258273) was dispatched
deliberately to capture the failure, because no *scheduled* run had failed yet — the
2026-07-31T10:17Z run predates the group deletion and went green. The next cron
(`43 7 * * *`) would have been the first. Both new tests were written red first, and each
is killed by a distinct mutation: removing the missing-group guard makes the run report
drift and exit 1 rather than exit 2, and restoring eager resolution reintroduces the
outage. See the 2026-08-01 amendment to
[ADR 0035](../docs/decisions/0035-variable-driven-runner-lanes/README.md).
