# 0044 — Gate provenance is bound to the run's entry workflow

- **Date:** 2026-08-02
- **Issue:** [Verjson/.github#279](https://github.com/Verjson/.github/issues/279)
- **Extends:** ADR 0036 (attestation-bound continuation), ADR 0039 (required-workflow provenance), ADR 0042 (privileged-merge reusable split)
- **Category:** merge-gate provenance / authorization (sensitive class)

## Context

ADR 0036 reduced the privileged merge's trust to one thing: an attestation
artifact produced by a run it can prove is the org's `ai-review-merge.yml`. One of
the three matchers that established "is the gate" read
`referenced_workflows[]` — accept the run if its file names
`Verjson/.github/.github/workflows/ai-review-merge.yml@<main's SHA>`.

`referenced_workflows` is a property of the workflow **file**, not of what
executed. GitHub resolves `uses` targets when it parses the file, so a job that
never runs — `if: false`, an unsatisfied `needs`, a skipped matrix — still puts
its callee in that array. The matcher therefore asserted "this file mentions the
gate", while the merge depended on "the gate ran and reached a verdict".

The three signals the privileged merge requires are then all mintable from a
single crafted workflow in a consumer repository, because nothing binds them to
each other:

1. **reference the gate** — one job holding the `uses` target under `if: false`;
2. **a successful `gate` check** — a job literally named `gate` that does nothing;
3. **an attestation** — upload `merge-attestation-<run_id>` with hand-written
   JSON naming the repository, PR, head SHA and run id, all of which the crafted
   run knows about itself.

The result is an `--admin` squash merge of arbitrary content into a protected
branch, bypassing AI review. Found by the adversarial security review in #277;
pre-existing, not introduced by any recent change.

### Why this was not live exploitation

`workflow_files_changed` stops the privileged merge — successfully, as a
human-review hand-off — for any pull request touching `.github/workflows/`. A
**fork** pull request cannot introduce the crafted file and then be merged by
this path, because adding it is itself the disqualifying change.

**That guard is load-bearing, not defence in depth.** It is the entire reason the
exposure is bounded to actors who already hold write access to the consumer's
base branch. Relaxing it — to only the merge workflows, or only for untrusted
authors — reopens the surface to anyone who can open a pull request. It is
commented as load-bearing at the function, and any change to it needs its own
decision record.

## Decision

**A gate run is trusted only when the gate is the run's ENTRY workflow.**

The run's `path` is the workflow file GitHub actually started, and it is a
non-nullable field of every workflow run (ADR 0039 transcribes it from live run
`30601252875`). `trusted_run` now requires `path` to equal
`.github/workflows/ai-review-merge.yml` as a **conjunct on all three matchers**:

| shape | previously | now |
| --- | --- | --- |
| `.github` running its own gate (`workflow_id`) | id equality | id equality **and** gate is the entry workflow |
| reusable caller (`referenced_workflows`) | file mentions the gate | file mentions the gate **and** the entry workflow is at the gate path |
| org required workflow (ADR 0039) | required-workflow URL + `path` + ruleset anchor | unchanged (it already required `path`; the clause is hoisted) |

The conjunct is deliberately not shape-selective. A matcher exempted from it
would carry the #279 hole for its own installation shape, and the exemption would
read as harmless.

### Why the entry check and not an HMAC

The issue offered two fixes. The HMAC — sign the attestation with a gate-only
secret — was rejected for this change: it introduces a secret that must be
distributed to, and held by, every consumer org, and a secret readable by the
producing workflow is readable by anything else that runs in the same repository
with `secrets: inherit`. It buys key management, not provenance.

The trade-off accepted instead: **trust is now bound to the run's entry point**,
which is precisely the property `referenced_workflows` fails to express. That is
a narrower claim than "the gate's jobs executed", and it is honest about what the
API can support — see the residual below.

### Residual exposure (not closed here)

An actor with **write access to a consumer's base branch** can place a crafted
file at exactly `.github/workflows/ai-review-merge.yml`. Its entry path, gate
reference at `main`'s SHA, check names and artifact contents are all identical to
an honest caller's.

Where the organization ruleset mandates the gate, one field does separate them:
an honest run was injected by the ruleset and carries a `workflow_url` under
`/actions/required_workflows/`, while a repo-local file carries
`/actions/workflows/`. The matchers are therefore **exclusive** rather than
additive — when `$required` holds, only the injected run is trusted, and the
id and reference matchers are unreachable. That closes the residual for every
repository in the required-workflow shape, which today is every Verjson
repository.

An earlier draft of this record claimed no runs-API field could separate the two.
That was wrong, and the code built on it merged a forged run in exactly the shape
this organization uses; the claim is corrected here rather than left to justify
closing #279. The residual that genuinely remains is confined to the
*reusable-caller* shape (`$required` false), where the id and reference matchers
are the only evidence available and a crafted file at the canonical path is
observationally identical to an honest thin caller. No repository is in that
shape today.

What it does close, completely, is the forgery as filed: any run whose entry
workflow is some *other* file (`ci.yml`, `release.yml`, a purpose-built
`merge-forge.yml`) that merely names the gate in a job that never runs.

Closing the residual durably needs provenance the consumer repository cannot
author — a GitHub-signed attestation verified with `--signer-workflow` — which is
already tracked as [#261](https://github.com/Verjson/.github/issues/261) and is
not part of this decision.

`ai-review-merge.yml` has **no equivalent guard on its own direct merge path**;
that is out of scope here and is filed separately.

## Amendment (2026-08-07, #279) — unsigned reusable callers are review-only

The entry-path check narrowed but did not close reusable-caller forgery. A
consumer can author the canonical caller path, reference the gate under
`if: false`, emit a successful `gate` check, and upload matching unsigned JSON.
No runs-API field distinguishes that file from an honest thin caller.

Privileged merge therefore no longer accepts `referenced_workflows` as trust
evidence. Only `.github`'s exact workflow id or an organization-ruleset-injected
required workflow may authorize merge. No current repository uses reusable
caller provenance for privileged merge. Cross-org reusable callers remain
supported for review, but require human merge until #261 supplies signed
producing-workflow identity.

This closes #279 without changing organization rulesets or weakening the
workflow-file guard. #261 remains open for the separate ambient ruleset
configuration risk in required-workflow provenance.

## Consequences

- **Consumer-visible:** a cross-org consumer using the ADR 0022 reusable shape
  receives review verdicts but never privileged auto-merge from unsigned caller
  provenance. No Verjson repository is affected — they all install the gate as
  the org required workflow (ADR 0039).
- The org required-workflow shape and `.github`'s own self-gate are behaviourally
  unchanged; their existing tests pass untouched.
- `scripts/ci-gate/entry-workflow-provenance.test.sh` (wired into `actions-ci`)
  extracts the shipped `run:` block and pins the binding: the legitimate shape
  merges on both the `pull_request_target` and dispatched paths, the
  referenced-only forgery is rejected on both, and absent/null/empty `path`,
  a non-array `referenced_workflows`, an empty run object and an empty run list
  all fail closed.
- Mutation evidence, since a guard that reads fail-closed and ships fail-open is
  a repeat failure mode here: making the conjunct constant-true fails 8 cases;
  defaulting an absent `path` to the trusted value fails 2; defining the
  predicate without applying it fails 9.
- `require-secrets.test.sh`'s run fixtures gained the `path` field. They modelled
  a payload the API never emits; carrying it is fixture fidelity, and those cases
  assert the *trusted* merge path, so an unrealistic fixture would have made them
  vacuous rather than strict.
