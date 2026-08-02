---
date: 2026-07-29
id: 20260729T204105Z
title: Runner admission is reconciled against routing daily
---

ADR 0033 routes by repository visibility, but only org settings decide whether a
repository can actually be *assigned* the lane routing picks. Nothing kept the
two honest. That is how #182 and #192 happened, and it still bit the one case
routing cannot fix: a newly created repository is in neither runner group, so
every job it emits queues with **no check run at all**.

#189 asked for routing that fails loudly at startup when a repo resolves to a
lane it cannot use. That is not expressible — GitHub has no "no runner matches"
failure; a job simply queues, for up to 24 hours. So the condition is detected on
a schedule instead, before it becomes someone's wedged PR.

`runner-admission-reconcile.yml` runs daily: it diffs every active repository's
visibility-derived lane against live runner-group membership, then files, updates
or closes a single issue. Observe-and-report only — it never mutates a runner
group, because pool admission is the org admin's security boundary. It also flags
a public repository admitted to the persistent pool, which is not exploitable
today (`allows_public_repositories: false` blocks assignment) but means one org
setting is all that separates fork code from credentialed runners.

Exit codes are the contract: `0` clean, `1` drift, `2` **undetermined**. The
third matters most — a reconciler that reports a clean org it failed to read
manufactures confidence, and the workflow treats `2` as a hard error that files
nothing.

The test caught exactly that bug during development: `die_undetermined` called
`exit 2` from inside a command substitution, which only ends the subshell, so an
API failure on the runner-group read left the parent running with empty
membership and reporting *drift* for an org it had never read. Every undetermined
path is now executed by a test, not merely asserted about.

Against the live org: 84 active repositories, no drift.

Closes #189. Refs #182, #192, #194, ADR 0033.
