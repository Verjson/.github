# 0171 — Inherit reusable environment secret context

- **Date:** 2026-09-10
- **Status:** Accepted
- **Issue:** [#1285](https://github.com/Verjson/.github/issues/1285)
- **Supersedes:** ADR 0166's no-grant reusable-secret transport decision only. Its role environments, exact main-only policy, admission and storage-isolation requirements remain authoritative.

## Context

After ADR 0166's implementation merged at `1664d518c13f207916f793b3218bee545209b8ee`, [rearm run 34431240566](https://github.com/Verjson/.github/actions/runs/34431240566) passed environment-policy admission but token minting received an empty private-key input. Earlier direct environment-job proofs did not cover reusable-call secret delivery. [GitHub's documentation](https://docs.github.com/en/actions/how-tos/reuse-automations/reuse-workflows#using-inputs-and-secrets-in-a-reusable-workflow) describes environment precedence; [runner issue 4453](https://github.com/actions/runner/issues/4453) reports that an environment binding alone does not resolve secrets without caller inheritance.

A unique random noncredential sentinel existed only in the exact main-only `ai-review-app` environment; authenticated metadata excluded an organization/repository copy. At immutable source `a5b55fbfb07d433b0ed7e07b36424ba710ee9062`, [main run 34433194313](https://github.com/Verjson/.github/actions/runs/34433194313) returned false with no declaration/grant, false with an optional declaration, false with an explicit empty grant, and true only with inheritance. [Same-source non-main run 34433211907](https://github.com/Verjson/.github/actions/runs/34433211907) denied all four jobs through native environment branch policy before any runner or step started. The [durable receipt](https://github.com/Verjson/.github/issues/1285#issuecomment-5612184570) records the controlled observations. No secret value was logged.

## Decision

Require `secrets: inherit` on every reusable edge leading to an App-key-consuming job, including the generated retry caller, canonical retry-to-privileged-merge edge, label rearm and release canary. Generated external callers remain pinned to one reviewed immutable organization contract SHA. Canonical relative calls resolve to the same trusted source revision. Preserve all fixed role environment inputs, keyless main-only policy prerequisites, terminal environment bindings, explicit policy-success dependencies and event-before-mint guards. Policy-only calls receive no inheritance. GitHub documents inheritance within the same organization or enterprise; the verified scope is Verjson-to-Verjson. Arbitrary cross-organization reusable consumers are not supported by this proven transport and must not be promised a declaration/forwarding workaround without separate evidence. Node publication and other non-App-key workflows retain their existing narrow grants.

Inheritance is the proven runtime mechanism, not proof of storage isolation. It makes every accessible caller secret available to the called workflow, including unrelated provider/package credentials and any remaining broad App copies. The fixed reviewed workflows reference secrets only where required and must never serialize the secrets context, perform dynamic secret lookup, expose it to PR-controlled code, or relax environment policy. An immutable pin limits unnoticed code replacement; it does not itself reduce the inherited secret set. Every key-bearing job must still pass native main-only environment admission before execution.

Do not invent a declaration-only or explicit-empty workaround: both failed the live control. Do not forward a real broad private-key value as a substitute for environment resolution. The chosen trade-off accepts broader context delivery to reviewed code because the narrower tested transports do not work, while preserving the durable goal of environment-only App-key storage. Model credentials formerly mapped individually on AI callers also travel through inheritance; this widening is explicit and reviewed.

Retire the temporary three-workflow probe and its test/routing registrations in this correction, preserving the runbook, immutable source and receipts. The operator removes its noncredential environment sentinel after operational verification. This change neither alters live keys/policies nor advances shared required-workflow rule `20722935` from compatible pin `c597d6908e3aa38d9a041c2150afadcbff32cf6d`.

## Rollout and consequences

Regenerate each affected caller and its exact contract test at the replacement immutable SHA. Do not adopt broken revision `1664d51`. Complete code and security review, green CI, exact pinned release-path verification and a live operational rearm/App proof before publishing the replacement adoption receipt. The controlled sentinel proves inheritance semantics separately from App identity; a real App mint while broad copies remain cannot establish exclusive storage provenance.

Prepare the entire selected consumer/shared-required-workflow cohort before coordinated pin advancement and broad-copy withdrawal. Keep #1285 open and preserve the interim acceptance until organization/repository App copies are absent and full cohort main-consumption/non-main-denial receipts exist. The metadata audit must continue to fail during partial migration. Pause dispatch on failure; do not restore broad forwarding or weaken branch protection.

## 2026-09-11 — Operational alerting on inherited access (#1297)

Static review bounds what the fixed reviewed workflows may reference, but inheritance
delivers every accessible caller secret to them at runtime, so detection must not end
at review time. Operators monitor App and token activity for access patterns the
reviewed workflows cannot legitimately produce — mints outside a recorded rearm,
release or review invocation, audit-log secret access from unexpected workflow paths,
or App token use against repositories outside the installation's expected set — and
treat any such observation as an incident, pausing dispatch as above rather than
waiting for the next static review. This adds an operational control; it changes no
transport, policy or pin decision recorded here.

## 2026-09-11 — Required-workflow invocation cannot resolve a relative policy call (#1285 canary)

An isolated canary (disposable private repository, dedicated organization ruleset
scoped to it alone, sentinel non-credential environment secret) exercised revision
`b050d745` as a ruleset required workflow. Both selectors — default branch and
`refs/heads/develop` — ended in `startup_failure` with zero jobs, while the
byte-identical workflow pair committed to the canary repository itself ran to
success at the same head SHA. The mechanism is the relative
`uses: ./.github/workflows/app-key-environment.yml` call: it does not resolve when
the workflow executes as an organization required workflow, so this section
corrects the "canonical relative calls resolve to the same trusted source
revision" statement above — that holds for same-repository `workflow_call` and
`pull_request_target` execution, not for the required-workflow path. Advancing
shared rule `20722935` to `b050d745` would therefore have hard-failed every
targeted pull request; the freeze on `c597d690` was correct.

The same canary resolved the develop-selector admission question for
`pull_request_target` execution: the main-only role environment admitted both a
main-targeted and a develop-targeted run (policy validation succeeded, the arm job
was admitted, and only the sentinel token mint failed, tolerated as designed),
because admission follows the trusted default-branch run context rather than the
pull request's base. Environment admission under *required-workflow* invocation
remains unverified for any revision — `b050d745` cannot start there and
`c597d690` binds no environment — so the fixed revision must repeat the canary
under required invocation before any pin advance.

The correction replaces the relative call with an absolutely pinned reference to
`app-key-environment.yml@b050d745`, the reviewed immutable revision whose copy is
byte-identical to this branch's. Trade-off: the policy check's trusted revision is
now named twice (the ruleset pin and the in-file pin) and both move only through
reviewed revision bumps; the alternative — inlining the policy job — was rejected
to keep one source of policy logic for the `workflow_call` consumers. All cohort
migration, broad-copy withdrawal and receipt gates above stand unchanged.

Durable receipts for every empirical claim in this section: the
[canary record on #1285](https://github.com/Verjson/.github/issues/1285#issuecomment-5640555699)
(rig, per-selector startup failures, local-copy discriminator, fixed-revision
required-invocation acceptance at exact head, and verified teardown), with full
run and job projections retained privately at
`.git/pm-runs/ready-queue-20260911-receipts/1285-canary/` in the owning checkout,
following ADR 0173's private-receipt convention for this public repository.
