# Runner routing & lanes

Where verJSON CI jobs run, and how to choose a `runs-on` value. The model is decided in
[ADR 0040](decisions/0040-runner-lanes-and-admission-axes/README.md) — read that for the
*why*, this for the *how*.

> **Verify, don't trust this page.** Every fact below was measured on **2026-08-01** and
> the command is quoted next to it. Runner fleets, groups, and billing all change without
> touching this file, and this document has been wrong before precisely because it was
> read as authoritative. If a decision depends on a number here, re-run its query first.

## TL;DR

- **Declare what the work *is*, not where it runs.** Use a lane variable:

  ```yaml
  runs-on: ${{ fromJSON(vars.VERJSON_LANE_TRUSTED || vars.VERJSON_LANE_FALLBACK || '["ubuntu-24.04"]') }}
  ```

- **Never hardcode a runner label or `ubuntu-latest`** in a Verjson workflow. That is the
  defect behind #175, #182, #192 and #203, and it has regrown four times.
- **The trailing `'["ubuntu-24.04"]'` is a portability contract, not a safety net.** It
  exists so an organization outside Verjson — which has none of these variables — can call
  a Verjson reusable workflow and land somewhere sane. It does **not** mean "if something
  is wrong, this will save you."
- **Admission is enforced by runner *groups*, never by a label.** `runs-on` lives in a file
  a pull request can edit, so a label is chosen by whoever writes the PR.
- Self-hosted runners have **no ambient Node** and a **persistent shared `~/.gitconfig`** —
  use `actions/setup-node` and idempotent git config, or the
  [`setup-verjson-node`](../.github/actions/setup-verjson-node/README.md) composite action.

## The four lanes

| Lane variable | Use for | Resolves to today |
|---|---|---|
| `VERJSON_LANE_TRUSTED` | ordinary organization CI; secrets available | self-hosted general pool |
| `VERJSON_LANE_UNTRUSTED` | fork/PR content; must not see secrets | self-hosted general pool |
| `VERJSON_LANE_PRIVILEGED` | the merge gate and its elevated token | self-hosted general pool |
| `VERJSON_LANE_FALLBACK` | organization-wide default when a lane is unset | configurable |

Pick by what the job **is**, not by where it currently runs: gate preflight/review that
touches PR content → `UNTRUSTED`; privileged merge → `PRIVILEGED`; everything else →
`TRUSTED`.

All three currently resolve to the same pool. That collapse is **deliberate and pending**,
not an oversight — the names describe an isolation topology that is defined but not
enforced. [#204](https://github.com/Verjson/.github/issues/204) is the restoration hook.

`UNTRUSTED` points at self-hosted even though hosted runners work, because a *private*
repository on hosted rides a spending ceiling (see [Cost](#cost-and-hosted-availability)).

## Three axes

| Axis | Mechanism | Appears in `runs-on`? |
|---|---|---|
| **Admission / trust** | runner **group** visibility | **No** — enforced org-side, not selected |
| **Capability** | **label** (`general`; `docker` if reintroduced) | Yes |
| **Provider / host** | operational attribute only (`do`, `hostinger`) | **Never** |

**A label cannot carry a security boundary.** Only group visibility is organization-side
and unbypassable. This is why there is no `secure`/`insecure` label: it would be a boundary
its own attacker gets to choose.

## Live fleet

```console
$ gh api /orgs/Verjson/actions/runners \
    --jq '.runners[] | "\(.name)\t\(.status)\t\([.labels[].name] | join(","))"'
gha-general-1..6   online   self-hosted,Linux,X64,gce,gate,GCP,general
hostinger          online   self-hosted,Linux,X64,manish
```

⚠️ **`gce` and `GCP` on those six runners are wrong, not merely legacy.** They are
DigitalOcean machines. Do not route new work by them, and do not read them as evidence of
a GCP fleet. They survive only until the #203 sweep completes — see
[Migration sequence](#migration-sequence).

`gate` on all six means the merge gate runs on the same hosts as untrusted pull-request
code. That is an **accepted risk**, recorded in ADR 0040: isolation was deferred to protect
CI speed. It is a decision on the record, not an oversight.

## Runner groups (the admission axis)

```console
$ gh api /orgs/Verjson/actions/runner-groups \
    --jq '.runner_groups[] | "id=\(.id) \(.name) vis=\(.visibility) public=\(.allows_public_repositories) default=\(.default)"'
id=1 GitHub  vis=all  public=true   default=true
id=3 manish  vis=all  public=false  default=false
id=4 GCP     vis=all  public=true   default=false
```

- **Group 4 is organization-wide with zero selected members.** It was widened out of band
  and **no ADR records who or why**; `/orgs/Verjson/audit-log` returns 404 for this token,
  so it cannot be attributed after the fact.
- **Group 1 is `default: true` and GitHub will not let a custom group be default.** A newly
  registered runner therefore lands in a public-accessible group with no label discipline
  unless `--runnergroup` is passed at registration time. Verify placement after registering
  any runner.
- Groups `6` and `7` were deleted and now 404. A reconciler that pinned group 6 by id broke
  on this (#266); resolve groups **by name**, and only for lanes that select them.

Group **ids** are the identity for admission — admitted repositories travel with the id
across a rename. Group **names** are referenced at runner registration
(`--runnergroup <name>`), so renaming a group can break provisioning in other repositories.

## Cost and hosted availability

The long-standing claim that hosted runners are "unfunded" for this organization and that
`ubuntu-24.04` is "a guaranteed failure" is **false**. Corrected in ADR 0040:

```console
$ gh api '/organizations/Verjson/settings/billing/usage?year=2026&month=7' | jq '
    [.usageItems[] | select(.sku == "Actions Linux")]
    | {first_paid: ([.[] | select(.netAmount > 0) | .date] | min),
       last_paid:  ([.[] | select(.netAmount > 0) | .date] | max),
       total_net:  ([.[] | .netAmount] | add)}'
{ "first_paid": "2026-07-13T00:27:10Z",
  "last_paid":  "2026-07-17T08:52:13Z",
  "total_net":  20.000000000000004 }
```

- **Public repositories run hosted freely.** `verjson-github-runner` used 836 minutes at
  `$0` in late July.
- **Private repositories are capped, not blocked.** Paid usage stopped at exactly $20.00 —
  a spending limit, i.e. a budget knob. Small fully-discounted amounts continued for
  private repositories afterwards.
- When re-running this, **group by `netAmount > 0`**. Aggregate `netAmount` hides the
  distinction because "free" and "refused" both render as `$0`.

## Retired: the Docker lane

Earlier revisions of this page required Docker/kind/buildx work to pin
`[self-hosted, docker]` on `gha-docker-1`, and stated that the general pool has **no Docker
socket**.

**Both are retired.** `gha-docker-1` is not in the fleet and no runner carries a `docker`
label (`gh api /orgs/Verjson/actions/runners` above), so the lane is unroutable. The owner
states that all live self-hosted runners have Docker Compose; that is **not independently
verified** — runner-local software is not visible through the API.

Recorded as retired rather than deleted because the no-socket claim was load-bearing for
earlier decisions. If a `docker` capability is reintroduced, it returns as a **label** on
the capability axis, not as a group.

## Where each check belongs

| Tier | Runs | Checks | Token |
|---|---|---|---|
| Resolver job | per job, hot path | lane variable exists and is a well-formed non-empty JSON array | none |
| Reconciler | scheduled | every lane resolves to ≥1 **online** runner; group admission | `ORG_ADMIN_TOKEN` |
| Required workflow | per PR, org-wide | no workflow hardcodes `runs-on` | none |

Availability is **not** checked on the hot path, deliberately: fork pull requests get no
organization secrets, so a resolver would have no token in exactly the untrusted case; a
runner online at resolve time may be offline at dispatch; and putting an org-admin token
call in 89 repositories' PR paths widens its blast radius. Availability is a fleet-level
fact and belongs in the scheduled reconciler
(`scripts/ci-gate/runner-admission-reconcile.sh`), which already holds that token in a
context that never executes pull-request code.

A required workflow runs as its **own check alongside** a repository's workflows. It cannot
inject `runs-on` into another workflow's jobs, and its outputs cannot cross into them. It
*enforces*; lanes *resolve*. Both are needed.

## Constraints every self-hosted job must respect

1. **No ambient Node.** GitHub-hosted images ship Node; these runners do not. Use
   `actions/setup-node` or `setup-verjson-node` — never assume `node`/`npm` is on PATH.
2. **Persistent, shared `~/.gitconfig`.** Runners are long-lived, so home gitconfig carries
   state between jobs. Setting a multi-valued key (e.g. `url.*.insteadOf`) collides with a
   prior job's entry (`cannot overwrite multiple values`). Use `--unset-all` then `--add`,
   or `setup-verjson-node`, which is idempotent.
3. **Retired — "the `meta` runner cannot resolve private composite actions."** This
   constraint applied to `gha-meta-1`/`gha-meta-2`, which are no longer in the fleet. It is
   kept numbered because [ADR 0016](decisions/0016-self-gate-runner-redundancy/README.md)
   cites it as "constraint 3"; renumbering silently would strand that reference. It says
   nothing about the current runners.

## Migration sequence

Order matters. Each step is safe only after the previous one lands.

1. **Create the lane variables** (`VERJSON_LANE_*`). Keep `VERJSON_RUNNER_*` in place —
   removing them mid-rollout breaks in-flight runs.
2. **Migrate workflows to the lane expression**, choosing the lane by what each job is.
3. **Rename groups onto the admission axis** (names describing admission, not hardware or a
   person). Read the provisioning call sites first: a rename that sends the next runner
   into the default public-accessible group is worse than a wrong name.
4. **Sweep the inline `runs-on` long tail** (#203).
5. **Only then delete `gce`, `GCP`, and `gate`** from the live runners.

⚠️ **Deleting the stale labels before step 4 makes those jobs queue forever with no check
run** — #182's silent-failure mode, which is the entire reason this programme exists. A job
with no matching runner does not fail; it waits.

## Related

- [ADR 0040](decisions/0040-runner-lanes-and-admission-axes/README.md) — this model
- [ADR 0035](decisions/0035-variable-driven-runner-lanes/README.md) — variable-driven lanes
- [ADR 0033](decisions/0033-self-hosted-runner-policy-by-visibility/README.md) — superseded
  visibility-tier model; its funding premise and group-4 description are both corrected by
  ADR 0040
- [Reusable Node workflow controls](node-workflows.md)
