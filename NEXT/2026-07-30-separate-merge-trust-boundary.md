# Separate PR review from privileged merge authority — 2026-07-30

The organization gate now keeps `ORG_ADMIN_TOKEN` exclusively in a trusted
base-branch execution path that never consumes PR code, artifacts, caches, environment
files, or outputs. Dependabot, Renovate, forks, and ordinary PRs share the credential-free
validation path; the trusted merger revalidates repository identity, immutable head SHA,
required checks, draft/hold state, and current PR state before a matched-head merge
([#230](https://github.com/Verjson/.github/issues/230), ADR 0036).

Manual and reusable dispatch are repository-local: operators run the workflow in the
repository owning the PR. The privileged guard reads every page of changed files and
repeats that check immediately before merge, so padded or late workflow changes require
a human merge.
