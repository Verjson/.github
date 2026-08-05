---
date: 2026-08-05
issue: 404
title: Centralize generated-artifact CI checks in a reusable workflow
---

New reusable workflow `.github/workflows/generated-artifacts.yml` (`on: workflow_call`)
owns checkout, lane-variable runner selection, `contents: read`, the timeout, and one
uniform failure report for generated-artifact validation. Consumers stop hand-writing a
`generated-docs` job — the copied plumbing that left `verjson-identity-lifecycle` queued
forever on the retired `[self-hosted, GCP]` label.

Checks are enumerated boolean opt-ins, never a command: `adr-index: true` runs
`scripts/gen-adr-index.sh --check`, and `changelog: true` runs the pinned contract's
`changelog.py validate` (plus `check-pr` on a pull request). Missing generator, stale
artifact and clean are reported distinctly, and a call with every check disabled fails
instead of reporting a green no-op.

`changelog: true` runs the same pinned engine as `changelog-validate.yml` and adds no
second render pass, so it replaces that caller rather than accompanying it. See
[ADR 0055](docs/decisions/0055-shared-generated-artifact-checks/README.md) and the caller
interface in [`README.md`](README.md).

`contract_ref` must be a full 40-character lower-case commit SHA, enforced by a first
step that runs before either checkout. `ref:` otherwise accepts a branch, a tag or
`refs/pull/<n>/merge` — and this repository is public, so an unpinned call could run an
outsider's contract engine on the Verjson lane. Abbreviated SHAs are rejected as well
(#312). Both checkouts set `persist-credentials: false`, and the contract checkout is
skipped for a call that is already invalid.

The changelog failure report now names the command CI ran —
`python3 .changelog-contract/scripts/changelog.py …`, the failing subcommand, and the
`contract_ref` to check out — instead of `scripts/changelog.py`, a path no consumer has
under ADR 0038.
