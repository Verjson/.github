---
date: 2026-08-01
issue: 275
title: Detect runners registered into the default runner group
---

The admission reconciler asked two questions — are repositories admitted to the lane their
visibility selects, and does each lane resolve to at least one online runner. A runner
registered **without** `--runnergroup` answers neither. It lands in GitHub's default group,
which is `visibility: all` with `allows_public_repositories: true` and has no label
discipline, so it is capacity that no lane selects and no policy governs. Nothing detected
it; ADR 0041 records placement as verified by hand.

The reconciler now fails closed on any runner sitting in the default group and names it.
Three details are deliberate:

- **The group is resolved by its `.default` flag, never by the id `1`.** The id is stable
  in practice, but pinning one is what took this job down for a week (#266). A listing with
  no default group is *undetermined*, not clean — GitHub always marks exactly one and a
  custom group cannot become it (ADR 0003), so its absence means the listing is not what we
  think it is.
- **Offline runners count.** An offline runner is still registered in the wrong group and
  rejoins the pool on its own, so filtering by status would hide the thing being looked for.
- **An unreadable group is undetermined, not empty.** Reading a 403 as "no runners there"
  is the fail-open shape #266 left in this file.

Names are selected in the script rather than in the API-side `--jq`. The test stub returns
fixtures verbatim and cannot exercise a server-side filter — a mutation that added
`select(.status == "online")` to that expression passed the entire suite, including the test
written to catch exactly it. Anything this check's correctness rests on is now evaluated on
data the tests control.

**Detection only.** The fix is `--runnergroup` at registration, which lives in
`verjson-cli-cloud`, outside this repository.
