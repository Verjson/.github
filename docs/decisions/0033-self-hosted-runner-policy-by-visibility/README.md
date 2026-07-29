# 0033 — Route runners by repository visibility, on configurable self-hosted pools

- **Date:** 2026-07-29
- **Amended:** 2026-07-29 — reconciliation gap closed by detection (#189)
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
   and the union covers all of them, so no repository that exists today hangs on
   admission. This is a *measurement*, not a structural guarantee — see the
   reconciliation gap under Consequences.
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

### What actually enforces the security boundary

Tier 4 keeps public repositories off the persistent pool, but the expression is
not what makes that binding — **tier 1 outranks it and is caller-controlled.**
On `pull_request` the caller workflow file comes from the PR head, so a fork of
a public Verjson repository can pass `runner: '["self-hosted","GCP"]'` and skip
tiers 2–4 entirely.

What stops it is org settings, recorded here because they are load-bearing and
invisible from this repository:

| Group | `allows_public_repositories` | Effect |
|---|---|---|
| 4 `GCP` | `false` | a public repo cannot be assigned this pool at all |
| 3 `manish` | `false` | same |
| 7 `docker-builders` | `true` | but `restricted_to_workflows` pins it to `publish-images.yml@refs/heads/main` |

Likewise, tier 3 sends fork PRs against *private* repositories to the persistent
pool; that is safe only because `members_can_fork_private_repositories` is
`false` at the org.

**Changing any of those three settings reopens a hole that this expression and
its tests cannot detect.** Admitting `.github` to group 4 "for capacity" is the
realistic version of that mistake.

**Both pools are org variables.** Verjson runners are on GCP today and moving to
DigitalOcean. Setting `VERJSON_RUNNER_DEFAULT` to `["self-hosted","do"]`
org-wide moves every consumer of every reusable workflow, with no PR to this
repository and no version bump for pinned callers. Unset variables resolve to
the literal defaults, so behaviour is unchanged until someone sets one — and
external callers, who have no Verjson variables, are unaffected by construction.

`vars` is available in `runs-on` (verified: actionlint reports the allowed
contexts there as `github, inputs, matrix, needs, strategy, vars`), which is
what makes this expressible at all. `env` is not — the constraint ADR 0031 cited.

**Value contract:** each variable must be a JSON array of label strings, e.g.
`["self-hosted","do"]`. A malformed value fails loudly — `fromJSON` throws at
job startup. A *well-formed but wrong-shaped* value does not: `"ubuntu-24.04"`
resolves to the unfunded hosted lane and `[]` to a job no runner can claim,
org-wide and instantly, for every consumer of every reusable workflow. Treat
setting these as a production change.

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
  allowlist. `runner-routing-policy.test.sh` asserts the routing *table* for the
  enumerated policy jobs, and — because enumeration alone let review append an
  inverted-policy job while the suite stayed green — sweeps **every** `runs-on:`
  line in the seven reusable workflows and requires a byte-identical decision
  suffix. The canonical suffix is derived from node-ci's `eligibility` job, so
  no copy of the policy lives in the test.
- `pulumi-ci`'s `validate` and `preview-admission` still take no `runner`
  input. They sit on the credential boundary of ADR 0027/0029, so a caller must
  not choose their pool; the test asserts that absence rather than trusting it.
- Adding a repository to a runner group no longer requires a change here. Making
  a repository **public** does — it moves to tier 4, which requires group-6
  admission. That is the one coupling left, and it is the security-relevant one.
- `actionlint.yml` is migrated too. It kept owner-wide isolated routing —
  the #182 pattern — which would have queued forever for the 79 private
  repositories outside group 6. Not live (its only `workflow_call` consumer is
  `verjson-cli`, which is admitted), but it was a loaded gun. Its
  `github-hosted-runner` input (ADR 0026) survives as an explicit opt-in; while
  billing is off that knob can only fail, which is a trap tracked in #189, but
  it is opt-in rather than a silent route.
- **Reconciliation gap — closed by detection, not by routing.** Group 4 is
  `visibility: selected` and members can create repositories, so a **newly
  created repository is in neither group** and hangs with no check run: the #182
  failure mode, in the one case routing cannot fix. GitHub offers no way to fail
  a job at startup because no runner matches — a job simply queues — so #189's
  "fail loudly" ask is not expressible in `runs-on`.

  `runner-admission-reconcile.yml` answers it a different way: a daily job diffs
  every active repository's visibility-derived lane against live runner-group
  membership and files (or updates, or closes) one issue. The condition is caught
  before it becomes someone's wedged PR rather than at the moment it wedges. It
  is observe-and-report: pool admission stays the org admin's boundary, so the
  reconciler never mutates a runner group.

  Its exit codes carry the contract — `0` clean, `1` drift, `2` **undetermined**.
  The third exists because the failure that matters most is reporting a clean org
  you never managed to read; the workflow treats `2` as a hard error and files
  nothing. Onboarding a new repository still means admitting it to group 4 (or 6,
  if public); the reconciler makes forgetting visible within a day.
- **Capacity:** tier 3 points all 82 private repositories at the `GCP` label,
  whose online members are `gha-gate-1/2/4` and `gha-runner-6` — three of which
  also carry `gate` and serve the merge gate. Heavy CI can starve the gate. Not
  a regression (`gce`/`GCP` are the same machines as before), but the headroom
  is thinner than the repository count suggests.
- Restoring Actions billing does not obsolete this ADR. Hosted stays the
  outside-caller tier only; Verjson work stays on self-hosted capacity.
