---
date: 2026-08-01
issue: 275
title: Detect runners registered into the default runner group
---

The admission reconciler asked two questions — are repositories admitted to the lane their
visibility selects, and does each lane resolve to at least one online runner. A runner
registered **without** `--runnergroup` answers neither. It lands in GitHub's default group,
which is `visibility: all` with `allows_public_repositories: true` and has no label
discipline, so it is capacity that no lane selects and no policy governs.
[ADR 0003](../docs/decisions/0003-runner-groups-gcp-github-manish/README.md) already records
this as a hand-verified operational caveat — a custom group cannot be made default, so a new
runner auto-lands in the public-accessible one and must be moved afterwards. Nothing checked
that it had been.

The reconciler now fails closed on any runner sitting in the default group and names it.
Three details are deliberate:

- **The group is resolved by its `.default` flag, never by the id `1`.** The id is stable
  in practice, but pinning one is what took this job down for a week (#266). A listing with
  anything other than **exactly one** default group is *undetermined*, not clean. Both
  directions matter: absence means the listing is not what we think it is, and taking the
  first of several would skip the rest, so a stray in the second one would exit 0 reporting
  that no runner sits in the default group — the very fail-open this check exists to close.
- **Offline runners count.** An offline runner is still registered in the wrong group and
  rejoins the pool on its own, so filtering by status would hide the thing being looked for.
- **An unreadable group is undetermined, not empty.** Reading a 403 as "no runners there"
  is the fail-open shape #266 left in this file.

Names are selected in the script rather than in the API-side `--jq`. The test stub returns
fixtures verbatim and cannot exercise a server-side filter — a mutation that added
`select(.status == "online")` to that expression passed the entire suite, including the test
written to catch exactly it. Anything this check's correctness rests on is now evaluated on
data the tests control.

The drift report describes the group it actually read rather than asserting
"admits public repositories", names a runner with no `.name` by its id instead of rendering
a blank, and gives both halves of the remedy — move the runner that is already there, and
register future ones with `--runnergroup`. The first half was missing; `--runnergroup` alone
fixes only the *next* registration, so the report would have re-filed daily while an
operator followed it correctly.

**Detection only.** The prevention lives in `verjson-cli-cloud`, outside this repository.
