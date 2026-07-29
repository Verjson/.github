# 0031 — Route node-ci on isolated-pool admission, not organization ownership

- **Date:** 2026-07-29
- **Issues:** Verjson/.github#182, Verjson/.github#173, Verjson/.github#175
- **Category:** reusable workflows / runner security boundary
- **Refines:** ADR 0030 (routing tiers unchanged; the Verjson tier is narrowed
  to the repositories actually admitted to the pool)

## Context

ADR 0030 defined three routing tiers for the reusable workflows: explicit
`runner` input, then `[self-hosted, isolated, linux, x64]` for Verjson callers,
then `ubuntu-24.04` for callers outside Verjson. #175 implemented tier 2 as
`github.repository_owner == 'Verjson'`.

That expression assumes every Verjson repository can be *assigned* an isolated
job. It cannot. Org runner group `isolated` (id 6) is `visibility: selected`,
and its repository allowlist holds four repositories:

```
$ gh api /orgs/Verjson/actions/runner-groups/6 --jq '{id,name,visibility}'
{"id":6,"name":"isolated","visibility":"selected"}
$ gh api /orgs/Verjson/actions/runner-groups/6/repositories --jq '.repositories[].full_name'
Verjson/.github
Verjson/verjson-cli
Verjson/verjson-cli-cloud
Verjson/verjson-cli-project-init
```

Every other consumer requests a label set that GitHub will never schedule for
it. The job does not fail — it queues indefinitely, so **no check run ever
reports**, and the merge gate waits out its full timeout before failing. This is
the same silent shape as the #148 startup-cap breakages: consumers see an
eternally pending gate and no diagnostic. Observed live on
Verjson/verjson-authn#87 and #88 (`ci / eligibility` queued from 08:49Z, gate
failed after ~30m).

The mismatch is structural, not a typo: **routing is written in this repository,
admission is granted in org settings.** Nothing made the workflow's assumption
answerable to the runner group's actual membership.

## Decision

`node-ci.yml` routes on the **onboarded repository**, not the owner:

1. an explicit `runner` input still wins (unchanged, both tiers);
2. `[self-hosted, isolated, linux, x64]` when `github.repository` is in the
   isolated-pool allowlist embedded in the expression;
3. `ubuntu-24.04` otherwise — including Verjson repositories not yet admitted.

The org runner-group allowlist is **not** changed here. Pool admission is a
security boundary owned by the org admin; a workflow PR is the wrong instrument
for widening it, and widening it is not required to stop the hang.

### Is this consistent with ADR 0030's intent?

ADR 0030's tier model is unchanged and this ADR does not supersede it. Its
*intent* is genuinely that Verjson repositories use isolated capacity rather
than GitHub-hosted Actions — that intent stands, and the allowlist is the
mechanism by which it becomes true per repository instead of assumed
org-wide. ADR 0030 even records the dependency ("do not merge until … the
isolated pool required by #173 [is provisioned]"); what #175 missed is that the
pool was provisioned with `visibility: selected`, so provisioning is *per
repository*, not once for the org.

The allowlist is therefore the correct interim state and not a retreat from
0030: it makes the workflow's route track a fact it cannot itself control, and
it fails **soft** (hosted, CI reports) rather than **silent** (queued forever,
nothing reports) for any repository the org admin has not yet onboarded. As
repositories are admitted to group 6, they are added to this list — or the group
moves to `visibility: all`, at which point the allowlist collapses back to an
owner check in a follow-up ADR. Either way the migration stays observable
instead of stalling PRs.

### Why the expression is duplicated

`eligibility` and `build-test` carry byte-identical expressions. GitHub Actions
supports no YAML anchors, and `runs-on` cannot read the `env` context, so a
single textual definition is not expressible. Resolving the runner once in
`eligibility` and consuming it via `needs` was rejected: `build-test` runs under
`if: always()` precisely so an eligibility failure cannot wedge CI, and that
would hand it an empty `runs-on`. Lockstep is enforced by test instead
(`runner-routing-policy.test.sh` fails on any drift between the two).

## Scope

Only `node-ci.yml` is changed. `node-release.yml`, `notify-umbrella.yml`,
`helm-ci.yml`, `ui-ci.yml`, and `pulumi-ci.yml` carry the same owner-wide
expression and have the same latent hang for non-admitted callers; they are
tracked separately rather than fixed blind in a hotfix for the live node-ci
breakage.

## Consequences

- Non-onboarded Verjson consumers get CI that runs and reports, on hosted
  runners, instead of a gate that hangs for 30 minutes and fails.
- Onboarded repositories are unaffected: they still route to the isolated pool.
- Trusted callers keep the `runner` override on both sides of the allowlist.
- Adding a repository to runner group 6 now requires a matching one-line change
  here. That coupling is deliberate — it is what keeps the routing honest about
  admission, and the test states the invariant out loud.
- `runner-routing-policy.test.sh` now evaluates the real extracted expression
  rather than pattern-matching it, so the routing table is asserted as
  behaviour: allowlisted → isolated, non-allowlisted Verjson → hosted, outside
  org → hosted, explicit input → wins. It also rejects any non-Verjson
  repository appearing in the allowlist.
