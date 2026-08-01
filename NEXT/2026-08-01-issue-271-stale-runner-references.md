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

The same advice had shipped **twice**. `.github/actions/setup-verjson-node/README.md` also
told consumers to use the `docker` label, in a usage block written to be copied verbatim,
and `docs/runner-routing.md` carried a ⚠️ asserting the `helm-ci.yml` bug was still live.
Both are corrected here; the first was found only because review asked whether the claim to
"close the class" was true, and it was not.

A regression guard closes it for real. Every check in `runner-routing-policy.test.sh` read
`runs-on:` lines, so a pin living in a **comment** was invisible to all of them — which is
how this survived. The new check binds every self-hosted label named in a bracketed
selector, in workflows *and* in `.github/actions/**` docs, to the declared policy set.

Its reach is stated in the test rather than implied: it matches bracketed selector lists on
one line, and does **not** match the YAML block-sequence spelling or a bare mention in
prose. A guard trusted past its reach is worse than none.

Two further holes review found in the guard itself: stripping only double quotes made the
legal YAML `['self-hosted', 'general']` fail as the bogus label `'general'`, and the
negative-control exemption applied repo-wide, so a genuine `retired-runner-label` route in
any other workflow would have been excused. The exemption is now scoped to the file owning
the fixture, and the check asserts that fixture still *exists* — deleting it would otherwise
leave the guard reporting on a control that was gone.
