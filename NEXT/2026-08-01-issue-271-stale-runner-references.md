---
date: 2026-08-01
issue: 271
title: Correct runner guidance that pointed at lanes and runners which no longer exist
---

`helm-ci.yml` told callers to pin their kind smoke tests to a `docker` label, described
as "the only runner with a Docker socket". No runner in the fleet carries that label — the
Docker lane was retired (ADR 0040) — so a caller who followed the advice got a job that
**queued forever with no check run**, #182's silent-failure mode. The guidance now routes
that job through the org variables like every other job, and says plainly that the
"every runner has Docker Compose" claim is an owner assertion rather than an API-visible
fact, because runner-local software cannot be verified through the API.

`.github/actionlint.yaml` claimed the `gate` and `meta` labels belong to `gha-gate-*` and
`gha-meta-*` runners. Neither runner name exists; `gate` is carried by the `gha-general-*`
fleet and no runner carries `meta` at all.

**No label was removed**, and that is the substantive finding of this change. The file
reads as this repository's own config and its header said the list was "kept minimal" —
labels that appear in a `runs-on` *here*. It is not: every consumer of the reusable
`actionlint.yml` sparse-checks this exact file as `.verjson-actionlint-policy/`, so the
list is the union of labels **any** Verjson workflow may name. Pruning the three labels no
`.github` workflow routes on — `GCP`, `meta`, `isolated` — would have failed actionlint in
every consumer repository still routing on them, and the inline `runs-on` long tail is
explicitly not swept yet (#203). The header now states the file's real scope and the
deletion order.

A regression guard closes the class rather than the instance. Every check in
`runner-routing-policy.test.sh` read `runs-on:` lines, so a pin living in a **comment** was
invisible to all of them — which is exactly how this survived. The new check binds every
self-hosted label named anywhere in a workflow, comments included, to the declared policy
set, and separately asserts that the label `actionlint.yml`'s self-test uses as a negative
control stays *undeclared* — declaring it would leave that self-test green while it proved
nothing.
