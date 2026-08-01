# 0035 — Variable-driven runner lanes with a temporary permissive lane

- **Date:** 2026-07-30
- **Issue:** [Verjson/.github#223](https://github.com/Verjson/.github/issues/223)
- **Supersedes:** ADR 0034's routing decision
- **Refines:** ADR 0033's visibility policy and ADR 0028's trust tiers

## Context

Runner routing currently conflates four concerns:

1. runner-group admission;
2. workload trust;
3. provider and location;
4. capabilities.

ADR 0033 separated private and public workloads using organization variables, but ADR
0034 temporarily hardcoded every Verjson job to `["self-hosted","general"]` when the
isolated fleet went offline. The exception restored delivery but also made the variables
inert. New repositories still depend on manual admission to selected runner group 4,
which recreates the indefinite queueing failure from #182 and #189.

The organization intentionally accepts a near-term lane with no workload-isolation
guarantee. That exception must be named honestly and remain mechanically separable from
the future hardened public/fork lane.

## Decision

### Groups authorize; labels describe; variables select

- Runner groups are repository/workflow admission boundaries.
- Runner labels describe stable lanes, provider/location metadata, lifecycle, and
  positive capabilities.
- Organization variables contain complete `runs-on` label arrays. Workflows do not
  compose arbitrary dimension fragments.
- Provider labels such as `GCP` and `gce` never define a default lane.
- GitHub-hosted execution remains the literal `ubuntu-24.04`, not a self-hosted label.

The target group model is:

| Group | Admission | Contract |
|---|---|---|
| trusted-private | all private repositories; public disabled | persistent normal CI |
| untrusted-public | all repositories; public enabled | disposable, credential-free public/fork CI |
| privileged-build | selected repositories and restricted workflows | host Docker, publishing, signing |
| operator | selected private repositories | exceptional infrastructure operations |

Group 4 keeps its legacy `GCP` name during this change to avoid coupling policy delivery
to provider-retirement work in #203. During the permissive exception it has
`visibility: all` and `allows_public_repositories: true`, so every current and newly
created repository can use the only online fleet. Renaming and tightening it belong to
the later trust-boundary migration.

### Routing

Reusable workflows resolve lanes in this order:

1. a governed explicit runner override, where the workflow contract permits one;
2. callers outside Verjson use `ubuntu-24.04`;
3. private Verjson repositories use `VERJSON_RUNNER_DEFAULT`;
4. public or unresolved-visibility Verjson repositories use
   `VERJSON_RUNNER_UNTRUSTED`.

Missing variables retain the compatibility fallback `["self-hosted","general"]`.
`VERJSON_RUNNER_UNTRUSTED` may temporarily fall back to `VERJSON_RUNNER_DEFAULT` during
rollout. Malformed configured JSON fails workflow evaluation loudly.

The merge-gate preflight always uses the untrusted lane because target visibility is
not available before it is scheduled. The gate job uses the target visibility resolved
by preflight; failed visibility lookup therefore remains on the untrusted lane.

### Temporary permissive posture

Until #204 delivers disposable public/fork capacity:

```text
VERJSON_RUNNER_DEFAULT   = ["self-hosted","general"]
VERJSON_RUNNER_UNTRUSTED = ["self-hosted","general"]
```

`general` is therefore a compatibility label for the temporary permissive lane:

- shared persistent hosts;
- public and fork-controlled code permitted;
- no workload-isolation guarantee;
- not represented as isolated, ephemeral, or hardened;
- normal token-permission and secret-boundary controls remain required.

The exception ends by changing `VERJSON_RUNNER_UNTRUSTED`, not by editing every
consumer workflow.

### Label taxonomy

New labels use positive namespaced dimensions:

- stable lanes: `lane-general`, `lane-untrusted`, `lane-privileged-build`;
- provider: `provider-gcp`, `provider-digitalocean`;
- location: `region-<provider-region>`;
- lifecycle: `lifecycle-persistent`, `lifecycle-ephemeral`;
- trust: `trust-private`, `trust-untrusted-pr`;
- capabilities: `cap-docker-host`, `cap-docker-rootless`, `cap-kvm`, `cap-gpu`.

Absence means a capability is unavailable. Negative capability selectors such as
`no-host-docker` are audit metadata only and must not become normal workload selectors.
Existing `general`, `GCP`, `gce`, `isolated`, and `untrusted-pr` labels remain until
#203 and the upstream provisioning migrations complete.

## Reconciliation

The daily reconciler validates:

- both lane variables exist, are visible to all repositories, and contain valid JSON
  label arrays beginning with `self-hosted`;
- visibility-derived repositories can access the group selected by their lane;
- organization-wide groups admit newly created repositories without membership edits;
- public admission matches the live temporary policy;
- each selector has at least one matching online runner;
- API or parsing uncertainty exits distinctly and never reports clean.

## Consequences

- New private repositories use the organization default without runner-group mutation.
- Public and unresolved repositories have a separately switchable route even while both
  variables select the permissive fleet.
- Provider migration does not require consumer-workflow edits.
- The temporary exception remains security-sensitive: public code executes on shared
  persistent hosts. This is explicit accepted risk, not a hardened untrusted lane.
- `visibility: all` with public access is reversible through the captured org pre-state.
- #201, #203, and #204 remain required follow-on work; this decision creates their
  stable policy seams rather than claiming they are complete.

## Rollback

Restore runner group 4 to `visibility: selected`, restore the captured organization
variables, and revert the implementing PR. Do not remove compatibility labels as part
of rollback.

## 2026-07-30 amendment — harden migration seams

The merge-gate preflight always uses the untrusted lane for Verjson direct execution.
It cannot know a cross-repository dispatch target's visibility until its API lookup
runs, so event-repository visibility could otherwise disagree with the downstream
gate once the variables diverge (#225).

Reconciliation accepts both the compatibility lane labels (`general`, `isolated`,
`untrusted-pr`) and their namespaced replacements (`lane-general`,
`lane-untrusted`). This keeps the reconciler valid through the label migration
specified above (#226).

## 2026-08-01 amendment — resolve runner groups by name, and only when selected

This restores the invariant already stated under *Reconciliation* — uncertainty exits
distinctly and never reports clean — which the implementation stopped being able to
honour. It is not a new decision and does not supersede anything (#266).

Groups 6 (`isolated`) and 7 (`docker-builders`) were deleted on 2026-07-31, leaving the
organization with groups 1 (`GitHub`), 3 (`manish`), and 4 (`GCP`). The reconciler pinned
`UNTRUSTED_GROUP_ID=6`, so every run 404ed and exited 2. It stayed correctly fail-closed
— it never reported a dirty organization as clean — but it reported *nothing*, which is
the same blind spot by a different route: a monitor that goes quiet exactly when the
thing it monitors stops existing.

Two properties now hold, and the second is the one that was actually broken:

- **Groups resolve by name** against the live listing (`GENERAL_GROUP_NAME`,
  `UNTRUSTED_GROUP_NAME`, both overridable), never by a pinned id. A group that a lane
  genuinely selects but that no longer exists still exits 2, now naming the group and
  listing the groups that do exist.
- **Only groups a lane actually selects are resolved.** Both lanes currently select
  `general`, so nothing routed to `isolated` at all: the job died fetching a group no
  decision depended on. A group nothing selects can no longer take the run down.

Group ids remain the stable identity for *admission* — admitted repositories travel with
the id across a rename — so a subsequent rename onto the admission axis does not change
who is admitted. Name resolution is how this job finds the group, not a claim that names
are the identity.

Review of the fix found three further ways the same "never report clean" invariant could
be evaded, all closed in the same change:

- Lane `case` statements had no `*)` arm. A future lane would leave the group variable
  unbound; `set -u` without `-e` aborts with **exit 1**, which the wrapper reads as drift
  and files an issue about. Undetermined must not be able to decay into a verdict.
- Group member/runner fetches used a per-page `[...]` collector under `--paginate`, so
  `jq -e` saw only the last page and a repository on page 1 of a `selected` group read as
  unadmitted — spurious drift against a healthy organization (#268).
- The workflow wrapper handled only exit 2 and then `exit 0` unconditionally, so an
  off-contract exit (127, or a `set -u` abort) finished **green with nothing filed** —
  the original blind spot one layer out. It now maps anything outside 0/1/2 to
  undetermined.

The wrapper's exit-code contract is now executed in test, not asserted structurally, by
extracting the workflow's `run:` block and driving it with a stub — the repository's
standard method for gate shell.
