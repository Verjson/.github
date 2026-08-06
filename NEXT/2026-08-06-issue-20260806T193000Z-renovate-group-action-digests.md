---
date: 2026-08-06
id: 20260806T193000Z
title: 'chore(renovate): group action digest bumps into one pull request'
---

Renovate now opens one pull request for all GitHub Actions digest bumps instead
of one per action, rebases only on conflict, and keeps at most three pull
requests open at a time.

The cost of a Renovate pull request in this organisation is not its diff. Each
one pays a full AI review pass through `ai-review-merge.yml` and holds a runner
on the shared pool while the gate polls, so the bill scales with pull request
count. `github-actions` is effectively the only manager here — there is no
`package.json` — and every pinned digest was arriving as its own pull request.

`rebaseWhen: "conflicted"` is the second half. Under the default, merging one
pull request rebases the rest, and each rebase costs another CI run and another
review; with a ruleset requiring branches to be up to date, that is quadratic in
the number of open updates. #292 means the re-review skip never fires, so none
of that work is deduplicated.

No `schedule` and no automerge. Batching to a weekly window would delay security
patches for a saving the grouping already gets, and auto-merging action digests
would remove human eyes from a supply-chain surface — which is the one place
this organisation should keep them.
