---
date: 2026-08-07
title: Record that one transient 500 on the PR file list reddens the privileged merge
issue: 490
---

`privileged_merge` reads the PR file list once, and a `500` there is fatal:

```
gh: Server Error: Sorry, this diff is temporarily unavailable due to heavy server load. (HTTP 500)
::error::could not inspect the complete PR file list
```

Hit twice within an hour on 2026-08-07, on #479 (run `31123514097`) and #486 (run
`31138710867`), with no change to either PR. A plain re-run of the one job cleared both;
`GET /pulls/<n>/files` answered normally from a shell at the same moment, and
githubstatus.com reported all systems operational — so this is a per-request 500 on a
loaded diff endpoint, not an incident to wait out.

Failing closed on an unreadable file list is correct — the workflow-files check depends on
it. The defect is that a *transient* read is treated like an *unreadable* one, in a job whose
own CI poll loop already retries the analogous `checks-unavailable` case for its full window.
It compounds [#475](https://github.com/Verjson/.github/issues/475): a red `privileged_merge`
poisons the gate run and re-dispatch cannot clear it, so one bad response costs a pushed
commit or a hand re-run.

The #341 entry is pruned from `CLAUDE.md` — it closed with `c60770c`, and a closed entry in
that list loads into every session while misreporting the state of the work.
