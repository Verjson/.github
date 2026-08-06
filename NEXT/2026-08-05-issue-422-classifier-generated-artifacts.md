---
date: 2026-08-05
issue: 422
title: 'Recognise generated-artifacts.yml as a changelog-contract caller'
---

`classify-repo-stacks.sh` matched only `changelog-validate.yml` when deciding
whether a repository is on the changelog contract. ADR 0055 landed
`generated-artifacts.yml`, whose inner job is also `validate`, so a caller job
named `changelog` emits the `changelog / validate` context the core check
contract requires (ADR 0058).

Adopters therefore classified `package=no`, and the conformance audit quietly
stopped requiring `changelog / validate` of exactly the repositories that had
migrated to the hardened path. That under-requires rather than wedges, which is
why it was silent: the survey kept reporting them `conformant`.

The classifier keys on the `changelog: true` **input**, not on the `uses:` line.
ADR 0055 enumerates the workflow's checks as boolean inputs, so a caller passing
only `adr-index: true` is not on the changelog contract, and demanding
`changelog / validate` of it would wedge a repository that never runs the
renderer. Because `with:` follows `uses:`, the input is reconciled after the
whole file is read rather than at the point the call is seen.

`generated-artifacts.yml` is also the migration target for #412 — it requires a
full 40-character commit SHA for `contract_ref`, where `changelog-validate.yml`
accepts a mutable ref. So adopters are precisely the population the audit most
needs to see.
