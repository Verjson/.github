# 0033 — Route runners by repository visibility, on configurable self-hosted pools

- **Date:** 2026-07-29
- **Issues:** Verjson/.github#189, Verjson/.github#185, Verjson/.github#192, Verjson/.github#182
- **Supersedes:** ADR 0031 (the isolated-pool repository allowlist)
- **Refines:** ADR 0030 (routing tiers), ADR 0028 (security tiers), ADR 0026, ADR 0027, ADR 0029

## Context

Three defects landed in sequence, and each fix inherited the previous one's
wrong assumption.

#175 routed every `github.repository_owner == 'Verjson'` caller to the
`isolated` pool. Runner group `isolated` (id 6) is `visibility: selected`, so
non-admitted repositories queued forever (#182). #184 and #192 replaced the
owner check with a repository allowlist and fell back to `ubuntu-24.04`.

**That fallback does not exist.** GitHub-hosted minutes are unfunded for this
organization (#189), so `ubuntu-24.04` is not a soft landing — it is a
guaranteed failure with no steps executed. Every Verjson job must land on
self-hosted capacity the caller is actually admitted to. There is no hosted
tier for Verjson-owned work, only for the published package's outside
consumers.

The allowlist itself was also the wrong mechanism. It encodes in workflow YAML
a fact that lives in org settings, so it is stale by construction: by the time
#192 merged, group 6 had gained `verjson-github-runner` and the expression did
not know. Nothing reconciled the two, and nothing could.

Measured admission, 2026-07-29:

```
$ gh api --paginate /orgs/Verjson/actions/runner-groups/4/repositories  # GCP
82 repositories
$ gh api --paginate /orgs/Verjson/actions/runner-groups/6/repositories  # isolated
Verjson/.github  Verjson/verjson-cli  Verjson/verjson-cli-cloud
Verjson/verjson-cli-project-init  Verjson/verjson-github-runner
$ gh api --paginate /orgs/Verjson/repos --jq '.[]|select(.private==false)|.full_name'
Verjson/.github  Verjson/verjson-github-runner
```

Two facts fall out, and together they remove the need for any allowlist:

1. **Every one of the 84 active repositories is admitted to group 4 or group 6**,
   and the union covers all of them. A self-hosted default cannot hang on
   admission.
2. **The public repositories are exactly the group-6-only repositories.** The
   allowlist was an imprecise spelling of "is this repository public".

## Decision

Routing resolves in four tiers, identically in every reusable workflow:

| # | Condition | Lane |
|---|-----------|------|
| 1 | explicit `runner` input | as given |
| 2 | caller outside Verjson | `ubuntu-24.04` |
| 3 | Verjson **private** repository | `vars.VERJSON_RUNNER_DEFAULT`, default `["self-hosted","GCP"]` |
| 4 | anything else | `vars.VERJSON_RUNNER_ISOLATED`, default `["self-hosted","isolated","linux","x64"]` |

**Tier 4 is a fail-safe terminal, not a fallback.** Public repositories reach
it, and so does any event whose payload carries no `repository.private`. The
ordering is deliberate: if visibility cannot be resolved, the job goes to the
ephemeral untrusted-PR pool, never to the persistent pool that holds ambient
credentials. A hang is recoverable; fork code running beside credentials is not.
This is the same fail-closed reasoning as #176 and ADR 0024.

**Both pools are org variables.** Verjson runners are on GCP today and moving to
DigitalOcean. Setting `VERJSON_RUNNER_DEFAULT` to `["self-hosted","do"]`
org-wide moves every consumer of every reusable workflow, with no PR to this
repository and no version bump for pinned callers. Unset variables resolve to
the literal defaults, so behaviour is unchanged until someone sets one — and
external callers, who have no Verjson variables, are unaffected by construction.

`vars` is available in `runs-on` (verified: actionlint reports the allowed
contexts there as `github, inputs, matrix, needs, strategy, vars`), which is
what makes this expressible at all. `env` is not — the constraint ADR 0031 cited.

### Why not fix the allowlist instead

Because it re-creates the same class of bug on every org-settings change. The
allowlist has to be *maintained in lockstep with something it cannot observe*.
Visibility is a property of the repository the workflow is already running in,
so tier 3/4 answers itself and cannot go stale.

## Consequences

- Verjson releases and CI run again on capacity that exists. #192's fix stopped
  the silent queue but sent the work to an unfunded lane; this lands it on the
  pool the repository is admitted to.
- The single-source/byte-identity machinery from ADR 0031 is retired with the
  allowlist. `runner-routing-policy.test.sh` now asserts the routing *table* for
  all nine policy jobs across all six reusable workflows, plus: no owner-wide
  route may reappear, no Verjson caller may reach hosted, and every workflow
  must keep its `vars` escape hatch.
- `pulumi-ci`'s `validate` and `preview-admission` still take no `runner`
  input. They sit on the credential boundary of ADR 0027/0029, so a caller must
  not choose their pool; the test asserts that absence rather than trusting it.
- Adding a repository to a runner group no longer requires a change here. Making
  a repository **public** does — it moves to tier 4, which requires group-6
  admission. That is the one coupling left, and it is the security-relevant one.
- **Known trap, not fixed here:** `actionlint.yml` still offers a
  `github-hosted-runner` input (ADR 0026). It is an explicit opt-in rather than
  a silent route, so the guard permits it, but while billing is off it can only
  fail. Tracked in #189.
- Restoring Actions billing does not obsolete this ADR. Hosted stays the
  outside-caller tier only; Verjson work stays on self-hosted capacity.
