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
- **Capacity and provider changes are variable changes.** New runners, more GitHub-hosted
  compute, a new provider — all of it is a `VERJSON_LANE_*` edit. Never a `runs-on:` edit,
  never a hardcoded pool, label, or runner-group name
  ([ADR 0041](decisions/0041-shared-admission-hosted-and-self-hosted/README.md)).
- **Both hosted and DO self-hosted serve both public and private repositories**, by
  decision. That is the steady state, not a gap.
- **The trailing `'["ubuntu-24.04"]'` is a portability contract, not a safety net.** In the
  bare form above it exists so an organization outside Verjson — which has none of these
  variables — lands somewhere sane. In the *reusable* workflows a foreign caller
  short-circuits at `github.repository_owner != 'Verjson'` first, so reaching the tail there
  means a Verjson lane variable was deleted or mistyped. Either way it does **not** mean "if
  something is wrong, this will save you" — `runner-admission-reconcile` reports the second
  case as drift.
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
| `VERJSON_LANE_FALLBACK` | **our** default when a lane is unset — switchable, not tied to GitHub-hosted | configurable |

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
gha-general-1	online	self-hosted,Linux,X64,general,pwsh
gha-general-10	online	self-hosted,Linux,X64,general
gha-general-2	online	self-hosted,Linux,X64,general,pwsh
gha-general-3	online	self-hosted,Linux,X64,general,pwsh
gha-general-4	online	self-hosted,Linux,X64,general,pwsh
gha-general-5	online	self-hosted,Linux,X64,general,pwsh
gha-general-6	online	self-hosted,Linux,X64,general,pwsh
gha-general-7	online	self-hosted,Linux,X64,general,pwsh
gha-general-8	online	self-hosted,Linux,X64,general
gha-general-9	online	self-hosted,Linux,X64,general
hostinger	online	self-hosted,Linux,X64,manish
```

Measured 2026-08-05. Three things changed from the snapshot this replaces, all load-bearing:

- **`gce`, `GCP` and `gate` are gone from the fleet.** The #365 sweep took them off the
  runners. Any workflow still naming one is not "using a legacy label" — it is unplaceable,
  and GitHub queues an unplaceable job forever with no check-run diagnostic. They are
  undeclared in `.github/actionlint.yaml` for that reason, so naming one now fails lint
  instead of hanging a pull request (#401).
- **`gate` no longer exists as a distinct selector**, so the merge gate rides `general`
  along with everything else. The accepted risk ADR 0040 records — gate work sharing hosts
  with untrusted pull-request code — is therefore not merely accepted but unavoidable at
  present, since there is no second lane to move to.
- **`pwsh` is real on 8 of 10 runners.** PowerShell suites no longer need a hosted runner.

## Runner groups (the admission axis)

```console
$ gh api /orgs/Verjson/actions/runner-groups \
    --jq '.runner_groups[] | "id=\(.id) \(.name) vis=\(.visibility) public=\(.allows_public_repositories) default=\(.default)"'
id=1 GitHub  vis=all  public=true   default=true
id=3 manish  vis=all  public=false  default=false
id=8 DigitalOcean  vis=all  public=true   default=false
id=9 verjson-runner-maintenance  vis=selected  public=false  default=false
```

Measured 2026-08-05, after the general pool was restored to `vis=all public=true`. It had
regressed to `vis=selected public=false` when the fleet moved into the `DigitalOcean`
group, which locked every public Verjson repository out of its own lane and wedged the
merge gate — see [ADR 0054](decisions/0054-public-repositories-admitted-to-the-general-pool/README.md).
Group 4 (`GCP`) no longer exists; the general pool is group 8.

- **The general pool's group is organization-wide and admits public repositories —
  deliberately.**
  [ADR 0041](decisions/0041-shared-admission-hosted-and-self-hosted/README.md) decides that
  hosted and DO self-hosted both serve public and private repositories for the foreseeable
  future, superseding ADR 0028 decision 4. The accepted risks and the best-practice North
  Star we are deviating from are recorded there — read it before assuming this is a
  misconfiguration. (It was found as an undocumented drift; ADR 0040 records that history.)
- **Group 1 (`GitHub`) is `default: true`, and per ADR 0003 a custom group cannot be made
  default. Never rename it** — it names GitHub's own default group and nothing else.
  A newly registered runner lands there, public-accessible and with no label discipline,
  unless `--runnergroup` is passed at registration time. Verify placement after registering
  any runner.

  ⚠️ **This is the *registration* default, not our routing default.** Two different things
  are called "default" and conflating them is a live hazard — see
  [ADR 0041](decisions/0041-shared-admission-hosted-and-self-hosted/README.md).
  **Verjson's default is `VERJSON_LANE_FALLBACK`, a variable**, and it is not tied to
  GitHub-hosted: it can point at the DO self-hosted pool, at hosted, or at a future
  provider, and switching it is a one-line org-variable edit.
- Groups `6` and `7` were deleted and now 404. A reconciler that pinned group 6 by id broke
  on this (#266); resolve groups **by name**, and only for lanes that select them.

**Never hardcode a group name.** Group **ids** are the identity for admission — admitted
repositories travel with the id across a rename — and names are runtime configuration.
This is the "no hardcoded `runs-on`" rule one level down: a name baked into code is an
org-settings fact frozen into a file that drifts.

Verified 2026-08-01: no literal group name appears in Verjson provisioning code.
`verjson-cli-cloud` takes `runnerGroup` as a validated runtime option; `verjson-cli-projects`
admits by **group id**. The name is still passed at registration, so check the *invocation*
before renaming, not the source.

## Cost and hosted availability

The long-standing claim that hosted runners are "unfunded" for this organization and that
`ubuntu-24.04` is "a guaranteed failure" is **false for public repositories and misleading
for private ones**. Corrected in ADR 0040:

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

**Both are retired, and the second is backwards.** `gha-docker-1` is not in the fleet and
no runner carries a `docker` label, so the pin is unroutable. More importantly, the owner
confirms (2026-08-01) that **all six group-4 runners are DigitalOcean machines and all
accept Docker**; `hostinger` in group 3 is the exception. Runner-local software is not
API-visible, so that is the owner's statement rather than a measurement — check it by
running a job.

**So Docker/kind/buildx work needs no pin at all** and belongs on the ordinary trusted
lane. A label earns its place by discriminating; one matching every runner in the group
carries no information. A `docker` label would only be justified again if some future
runner *lacked* the capability.

`helm-ci.yml` and `setup-verjson-node`'s README used to tell callers to pin the `docker`
label, which queued forever with no check run. Both were corrected in
[#271](https://github.com/Verjson/.github/issues/271), and
`runner-routing-policy.test.sh` now fails any workflow that names a label the central
actionlint policy does not declare.

Recorded as retired rather than deleted because the no-socket claim was load-bearing for
earlier decisions.

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

1. ✅ **Create the lane variables** (`VERJSON_LANE_*`). Keep `VERJSON_RUNNER_*` in place —
   removing them mid-rollout breaks in-flight runs. All four exist org-wide and every one
   resolves to the general pool today.
2. ✅ **Migrate workflows to the lane expression**, choosing the lane by what each job is.
   Done for every `runs-on:` in this repository on 2026-08-05: no workflow here names a
   fleet label any more, and `scripts/ci-gate/runner-routing-policy.test.sh` fails if one
   reappears. **`VERJSON_RUNNER_*` stays set** — consumers pinned to an older reusable-
   workflow SHA still read those variables, and deleting them would strand exactly the
   repositories that have not re-pinned. `VERJSON_RUNNER_FASTLANE` and
   `VERJSON_RUNNER_OVERFLOW` are deliberately *not* folded into the lane names: they select
   hosted-versus-self-hosted, an orthogonal axis, and their `["ubuntu-24.04"]` value is a
   GitHub-provided identifier rather than a fleet label that can rot.
3. **Rename groups onto the admission axis** (names describing admission, not hardware or a
   person). Group 1 (`GitHub`) is never renamed — it names GitHub's own default group.
4. **Refresh the labels — additively first.** Every label on the live runners is being
   corrected, not just the obviously wrong ones. Add the accurate labels (`do`, and the
   capability labels the fleet actually has) while the stale ones remain in place, so
   nothing that still selects an old label breaks mid-migration.
5. **Sweep the inline `runs-on` long tail** (#203), so nothing selects a stale label.
6. **Only then delete the stale labels** — `gce`, `GCP`, `gate`.

⚠️ **Steps 5 and 6 ran out of order (2026-08-05).** The labels came off the fleet while
the inline `runs-on` long tail was still selecting them, which is the failure this ordering
exists to prevent. `Verjson/verjson-identity-lifecycle`'s `generated-docs` job queued
indefinitely on `[self-hosted, GCP]` with no check-run diagnostic (fixed in
`35c1efa1`) — #182's silent-failure
mode, reproduced exactly. The remediation is therefore still open (#365), and the remediation is now
detection rather than ordering: dead labels are undeclared in `.github/actionlint.yaml`, so
a repository still naming one fails lint with a file and line instead of hanging (#401).

⚠️ **Deleting a stale label before the sweep in step 5 makes those jobs queue forever with
no check run** — #182's silent-failure mode, which is the entire reason this programme
exists. A job with no matching runner does not fail; it waits. This is why the label
refresh is additive first and subtractive last: at every intermediate point, both the old
and new selectors resolve.

## Related

- [ADR 0040](decisions/0040-runner-lanes-and-admission-axes/README.md) — this model
- [ADR 0035](decisions/0035-variable-driven-runner-lanes/README.md) — variable-driven lanes
- [ADR 0033](decisions/0033-self-hosted-runner-policy-by-visibility/README.md) — superseded
  visibility-tier model; its funding premise and group-4 description are both corrected by
  ADR 0040
- [Reusable Node workflow controls](node-workflows.md)
