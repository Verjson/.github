# 0211 — Signed merge-gate provenance binds the canonical required workflow through captured claim predicates

- **Date:** 2026-09-27
- **Status:** Accepted (design and verifier only; no signing is rolled out)
- **Issue:** [Verjson/.github#1339](https://github.com/Verjson/.github/issues/1339)
- **Supersedes in part:** [ADR 0077](../0077-private-repository-gate-restoration/README.md)'s residual-risk clauses (#261 and the captured-credential prerequisite); its restored unsigned gate stays in force
- **Category:** merge-gate provenance and identity (sensitive class)

## Context

ADR 0077 reverted keyless signing for the merge gate because a Sigstore certificate
issued to a required workflow executing inside a **private** consumer repository had not
been proven to bind the canonical workflow rather than the consumer's own execution. It
required, before any future signing design, "a captured private-consumer credential/bundle
test proving its exact verifier predicates".

That capture now exists. On 2026-09-27 a temporary organization ruleset (24059547, since
deleted) injected `Verjson/.github/.github/workflows/oidc-claims-probe-1339.yml` at
`948cc641a0612822c916924d4c88f0d6f668cf0c` as a required workflow into the private scratch
repository `Verjson/demo-repository`; PR #13 there (closed unmerged) produced run
36288038538 with `workflow_url` under `actions/required_workflows/368060021`. The workflow
requested the job's OIDC token, masked the token and every JWT segment, removed
`jti`/`exp`/`iat`/`nbf`, and printed only the decoded claims. The redacted claim set is
committed verbatim as the `genuine` fixture in `config/merge-gate-provenance-fixtures.json`.

What the capture shows for an injected required workflow in a private consumer:

| claim | value | bound to |
| --- | --- | --- |
| `job_workflow_ref` | `Verjson/.github/.github/workflows/oidc-claims-probe-1339.yml@refs/heads/main` | canonical |
| `job_workflow_sha` | `948cc641…` (the SHA stored in the ruleset, not the consumer tree) | canonical |
| `workflow_ref`, `workflow_sha` | identical to the `job_workflow_*` pair | canonical |
| `repository`, `repository_id`, `sub`, `ref`, `sha`, `actor` | the consumer's | consumer |
| `repository_owner_id` | `279365001` | organization |
| `runner_environment` | `github-hosted` (the gate's private-target lane) | lane |

The consumer's identity therefore never enters the `*_workflow_ref`/`*_workflow_sha`
claims of a required workflow. In a reusable-call shape (a consumer-authored caller
invoking a canonical workflow), `workflow_ref`/`workflow_sha` name the caller instead;
that difference is the discriminator ADR 0077 lacked.

Two limits of the capture are recorded rather than papered over. The probe ran on
`pull_request`, so its token binds the ephemeral merge ref (`ref: refs/pull/13/merge`,
`sub: repo:<repository>:pull_request`) and its `sha` is the merge commit
(`286094e…`), **not** the PR head (`d66f63e…`); the live gate `gate-rearm.yml` is injected on
`pull_request_target`, whose token binds the base branch (`ref: refs/heads/<base>`,
`sub: repo:<repository>:ref:refs/heads/<base>`). The predicates therefore accept each
event with exactly its documented shape, and the `pull_request_target` shape is carried as
a labelled, provisional fixture derived from GitHub's documentation until a gate-rearm
run is captured the same way.

## Decision

A signing design for the merge gate must verify, as certificate policy over the Fulcio
extensions that carry these OIDC claims, exactly the predicates implemented in
`scripts/ci-gate/merge-gate-provenance-claims.py`:

1. `iss == https://token.actions.githubusercontent.com`.
2. `repository_owner_id == 279365001` and `repository_owner == Verjson` (the id is the
   identity; the name is a display check).
3. `job_workflow_ref == Verjson/.github/.github/workflows/<gate>.yml@refs/heads/main`
   **and** `job_workflow_sha == <the SHA the ruleset stores>`. A branch ref alone accepts
   any commit of `main` and is never sufficient.
4. `workflow_ref == job_workflow_ref` and `workflow_sha == job_workflow_sha`: the
   workflow must be the injected top-level workflow, not a canonical workflow reached
   through a consumer-authored caller.
5. Event shape, one of exactly two: `event_name == pull_request` with
   `ref == refs/pull/<n>/merge` and `sub == repo:<repository>:pull_request`; or
   `event_name == pull_request_target` with `ref == refs/heads/<base_ref>` and
   `sub == repo:<repository>:ref:<ref>`. `repository` must be owned by
   `repository_owner`.
6. `runner_environment` in the reviewed lane set (`github-hosted`, `self-hosted`).
7. `run_id`, `run_attempt`, `sha`, `repository_id` present. `sha` is the commit the token
   was minted for — the merge commit on `pull_request`, the base head on
   `pull_request_target` — and binds the signature to that run; the gate receipt's
   `expected_head_sha` is not in the token and stays a receipt-side check.

`repository_visibility`, `sub`, and `repository` are consumer facts: they identify *whose*
pull request was gated and must never be used to establish that the *canonical* workflow
ran. Every value is compared as an exact string; a missing, empty, or non-string claim is
a violation, never a default.

Certificate counterparts, for the rollout that binds these to Fulcio extensions
(sigstore/fulcio `oid-info.md`, GitHub Actions issuer): `iss` → 1.3.6.1.4.1.57264.1.8;
`job_workflow_ref` → .1.9 (as a `https://github.com/` URL, normalize before the bare
compare) and `job_workflow_sha` → .1.10; `runner_environment` → .1.11; `repository` →
.1.12 (URL form) and `repository_id` → .1.15; `repository_owner` → .1.16 (URL form) and
`repository_owner_id` → .1.17; `sha` → .1.13; `ref` → .1.14; `workflow_ref`/`workflow_sha`
→ .1.18/.1.19; `event_name` → .1.20; `run_id`+`run_attempt` → .1.21 (run invocation URI);
`repository_visibility` → .1.22 (carried, deliberately not a predicate). `sub` has no
extension: it is a token-only redundancy check over `repository`/`event`/`ref` and cannot
be enforced from a certificate alone; the rollout must enforce `ref` (.1.14) in its place.

`scripts/ci-gate/merge-gate-provenance-claims.test.py` holds the genuine capture to those
predicates and asserts that twelve tampered variants each fail on the predicate that
names their tampering: consumer-authored workflow, reusable call from the consumer,
reusable call pinned to the canonical SHA, stale canonical SHA, branch-only ref without
SHA, foreign owner with the same name, repository outside the owner, foreign issuer, push
event, `pull_request_target` whose `sub` names another ref, unreviewed runner environment,
and canonical path swapped. The tampered table and the expectation table are cross-checked
so neither can grow silently; the `pull_request_target` fixture is asserted to carry its
"not a capture" label.

## What this does not do

- No signing, attestation, or certificate verification is rolled out. The unsigned,
  conjunctively authenticated gate from ADR 0077 remains the deployed boundary.
- The verifier evaluates a claim set; it does not fetch tokens, parse certificates, or
  talk to Sigstore. Wiring it to a real bundle is the rollout decision, which needs its
  own ADR with the signing identity, the transparency-log policy, and the fallback.
- One capture from one hosted `pull_request` run. `runner_environment: self-hosted` and
  the whole `pull_request_target` shape are admitted from configuration and documentation,
  not from captures; a gate-rearm capture (self-hosted lane, `pull_request_target`) must
  be attached to #1339 before a rollout relies on either.

## Consequences

- ADR 0077's residual risk (#261) is resolved as a specification: the predicates that
  bind the canonical workflow are known and tested against real private-consumer claims.
- The probe workflow is deleted in the same change that lands the fixtures; the capture
  procedure (temporary ruleset, one PR, masked claims, delete both) is reproducible from
  the git history of `oidc-claims-probe-1339.yml` at `948cc641…`.
- A future gate signing rollout must cite this ADR and run the test against the exact
  workflow path and ruleset SHA it binds.
