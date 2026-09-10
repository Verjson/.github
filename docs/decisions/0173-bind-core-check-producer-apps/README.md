# 0173 — Prepare exact App bindings for organization core checks

- **Date:** 2026-09-10
- **Status:** Accepted
- **Issue:** [#1303](https://github.com/Verjson/.github/issues/1303)
- **Scope:** Reviewed preparation; no live ruleset mutation or consumer change.

## Context and evidence

Organization rulesets `20513599` and `20515817` require four status contexts without
producer App bindings. Canonical privileged-merge conformance rejects those missing
identities. Weakening that validator would hide the policy gap.

Authenticated reads on 2026-09-10 selected the actual property-based cohorts: 25
repositories for `changelog / validate`, and 23 for each of `ci / build-test`,
`ci / eligibility`, and `changelog-contract`. Every one of the 94 exact check-run
observations identified App `15368`, slug `github-actions`, owner `github`. Evidence
came from default-branch or same-repository PR heads, with matching check head SHAs;
no identity was inferred from an optional Node-floor check. The observed results
include 88 successes and six failures, with the oldest completion on August 29.
This establishes observed producer identity, not all-green adoption readiness.

This repository is public. Full repository names, run URLs and commit/check
identities stay in private local PM receipts under
`.git/pm-runs/closure-sweep-20260910-receipts/1303-producers/` in the owning checkout.
The public `config/required-check-bindings/observation.json` retains only aggregate
counts, observation age and hashes of the private evidence files. Tests use synthetic
repositories and receipts. Do not publish private evidence in PR bodies or logs.

## Decision

Prepare exact before, after and rollback artifacts in
`config/required-check-bindings/`. Each after payload adds only
`integration_id: 15368` to its existing required contexts: one field in rule
`20513599`, three in `20515817`. Keep the existing contexts, selectors, enforcement,
branch conditions, status-check options and bypass actors byte-for-byte equivalent
as JSON values. The rollback payload is the original writable policy projection.

The App binding restricts which App can satisfy a context; it does not prove the
workflow path, trusted source revision or freshness by itself. Consumer generated
`required_checks` lists and canonical workflow/App/head verification remain
mandatory. In particular, retain the supported `changelog-contract` context even
when a consumer is behind the canonical generated caller.

`scripts/required-check-bindings.py` supports only `render` and `dry-run`, with no
mutation mode. Offline rendering validates exact payload deltas and labels private
evidence unvalidated unless the operator supplies its matching local directory.
With private evidence it checks hashes, complete cohort/context coverage, producer
identity, exact heads and duplicate/type boundaries. Dry-run requires that evidence,
then re-reads both complete ruleset preimages, the entire selected property cohort
and all 94 historical check records using fixed `github.com` GET endpoints. Ambient
`GH_HOST` cannot redirect those reads. A changed snapshot or incomplete/unreadable
record fails closed. The output never includes private repository/run/head data.

```bash
python3 scripts/required-check-bindings.py render > binding-proposal.json
python3 scripts/required-check-bindings.py render --evidence-dir "$PRIVATE_RECEIPTS"
python3 scripts/required-check-bindings.py dry-run --evidence-dir "$PRIVATE_RECEIPTS"
python3 scripts/required_check_bindings_test.py
```

The 2026-09-10 path-boundary review found that literal `.` and `..` repository
names could pass the original lexical checks. One shared repository pattern now
rejects both in cohort admission and API paths before any subprocess invocation;
negative controls verify that boundary while preserving `.github` and ordinary
dotted/hyphenated names. This restores the fixed-endpoint decision above.

The private directory must contain the reviewed `cohort.json` and
`producer-checks.jsonl` files matching the public hashes. Offline synthetic fixtures
exercise complete/missing/duplicate coverage, wrong Apps, exact four-field deltas,
rollback fidelity, snapshot/cohort drift, fixed-host GET-only reads and refusal of
mutation commands. A successful dry-run only revalidates the historical observations;
it does not execute consumer workflows, establish current mergeability or authorize
activation. Preserve the distinction between these historical checks and fresh
operational evidence.

## Separately authorized activation and recovery plan

1. Review the exact public payloads with the private evidence, producer observation
   age and the real selected cohort. Refresh default branches, workflow identities,
   current-head evidence and both full before snapshots immediately before seeking
   live authorization. Any producer/cohort change requires a new reviewed plan.
2. Under explicit live authorization, re-read each complete preimage immediately
   before its single intended PUT. Only the reviewed four App-binding additions are
   permitted. Preserve a durable intent, original snapshot, candidate digest and
   write outcome. This tool has no PUT implementation and does not perform the step.
3. Read back each full ruleset and effective default-branch policy, require the exact
   candidate projection, and record its update/activation time. The two rulesets
   cannot be updated atomically: record any partial state. Uncertain writes require
   authenticated reconciliation; never retry or restore blindly.
4. Obtain fresh successful and failing PR-head controls for all four required
   contexts, with exact producer/workflow/head identities, and verify that a
   non-selected repository is unaffected. Verify the autonomous lane uses complete
   generated `required_checks` lists and preserves all existing bypass semantics.
5. Rollback is a separate explicitly authorized action using the preserved original
   projection only after re-reading and matching the known postimage. Reconcile
   drift first; do not overwrite another administrator's changes. Read back and
   record any rollback. Restoring unbound checks also restores the adoption blocker,
   so do not call that a successful rollout.

After verified activation, coordinate consumer adoption and refresh ADR0172's
reviewed Node-floor baseline snapshot before #1274 can proceed. Consumer-specific
floor bindings remain owner work. This PR references #1303; merging preparation
closes neither #1303 nor the disabled Node-floor rollout and grants no live authority.
