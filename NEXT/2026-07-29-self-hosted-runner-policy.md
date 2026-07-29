# Reusable workflows route by visibility onto configurable self-hosted pools — 2026-07-29

`ubuntu-24.04` was never a fallback. GitHub-hosted minutes are unfunded for this
org (#189), so every route that "degraded" to hosted was a guaranteed failure —
including the one added hours earlier by #192 to stop releases queueing. The
queue stopped; the release still could not run.

All six reusable workflows now share one policy (ADR 0033, superseding the
ADR 0031 allowlist), applied to all nine jobs that carry it:

1. explicit `runner` input wins;
2. a caller **outside Verjson** gets `ubuntu-24.04` — portability, their billing;
3. a Verjson **private** repo gets `vars.VERJSON_RUNNER_DEFAULT`
   (default `["self-hosted","GCP"]`);
4. everything else gets `vars.VERJSON_RUNNER_ISOLATED`
   (default `["self-hosted","isolated","linux","x64"]`).

Tier 4 is a fail-safe terminal, not a fallback: public repos reach it, and so
does any event carrying no `repository.private`. Unresolved visibility must land
on the ephemeral untrusted-PR pool, never on the persistent pool that holds
ambient credentials.

**The repository allowlist is gone.** It encoded org-settings state in workflow
YAML, so it was stale by construction — group 6 had already gained
`verjson-github-runner` while the expression still listed four repos. Measured
admission shows the allowlist was an imprecise spelling of "is this repo
public": all 84 active repos are admitted to the GCP or isolated group, and the
public repos are exactly the isolated-only ones.

**Pools are now configuration.** Verjson runners are on GCP today and moving to
DigitalOcean; setting `VERJSON_RUNNER_DEFAULT` org-wide moves every consumer of
every reusable workflow with no PR here and no version bump for pinned callers.
`vars` is usable in `runs-on` (verified — actionlint reports the allowed
contexts there as `github, inputs, matrix, needs, strategy, vars`); `env` is not,
which is the constraint that blocked single-sourcing before.

`runner-routing-policy.test.sh` asserts the routing table for all nine jobs and
adds three file-level guards: no owner-wide route may reappear, no Verjson
caller may reach hosted, and every workflow must keep its `vars` escape hatch.
`pulumi-ci`'s `validate`/`preview-admission` keep no `runner` input by design
(ADR 0027/0029 credential boundary) and the suite asserts that absence.

Closes #185. Refs #175, #182, #184, #189, #192, ADR 0033, ADR 0031.
