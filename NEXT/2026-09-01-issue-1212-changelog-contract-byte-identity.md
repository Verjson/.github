---
date: 2026-09-01
issue: 1212
impact: patch
title: the audit byte-compares the generated changelog-contract.yml (pr-gate) artifact, not just its shape
---

`scripts/gen-changelog-caller.sh` has produced a fifth generated artifact since
#935 — the `pr-gate` mode that writes `.github/workflows/changelog-contract.yml`.
`generated_contract_identity_for_repo` byte-compared the other four generated
artifacts against fresh generator output, but never this one: the audit only
checked its *shape*, via `required-checks-workflow.py` (does some unconditional
job run the contract test on `pull_request`). A hand-written job satisfying that
shape passed — even though the generated file is what carries the pinned
runner selection and the `persist-credentials: false` hardening from #959. Four
repositories (`verjson-authn`, `verjson-graphql-conventions`, `verjson-infra`,
`verjson-leads`) carried exactly this kind of hand-written duplicate,
undetected, for months.

`.github/workflows/changelog-contract.yml` is now fetched and byte-compared
like the other four artifacts. The one argument that varies `pr-gate`'s output,
`--untrusted-runner`, is not recorded anywhere else the audit reads, so it is
recovered from the artifact's own `runs-on:` line — which `emit_pr_gate` renders
as a bare (unquoted) `[label, label]` flow sequence, not JSON. Any shape other
than the literal default or that exact rendering faults closed
(`generated-contract-runner-shape-invalid`) rather than best-effort-parsing a
hand-edited value into matching itself.

Verified against a full, live, read-only, unscoped org audit (25 conformant, 3
nonconformant, 6 unclassified, 0 unaudited): every node-stack repository
reports `result=conformant` with zero `changelog-contract`-related faults,
including all four originally-affected repositories. The 3 nonconformant and
6 unclassified repos fail for pre-existing, unrelated reasons (a caller job
naming mismatch; a missing `verjson-stack` repository property). This
confirms the fix does not regress any currently-conformant repository.

Found while working #731.
