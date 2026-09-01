---
date: 2026-09-01
issue: 1203
impact: minor
title: Reconcile derived release inputs before minting the release credential
---

Container releases can now reconcile derived build inputs — a Dockerfile base pin, a
deployment values file — to the just-published immutable digest inside the same release
commit and tag, through an opt-in hook that runs after the provenance-verified manifest
exists and before the release App token is minted.

The hook is declared at generation time with
`scripts/gen-container-release.sh workflow <sha> [config] --reconcile-allow <path>...`,
which bakes the reviewed file allowlist into the generated caller's `with:` block. It is
never a `workflow_dispatch` input, so a releaser cannot widen it; the command is always the
consumer's `scripts/release-reconcile.sh`, so there is no shell fragment in the input
surface at all. Enforcement is `scripts/container_release_reconcile.py`, run from the pinned
`.container-release-contract/` checkout rather than a consumer-side copy.

Everything about it is fail-closed. It requires a clean tracked tree, builds the hook's
environment from scratch rather than filtering the runner's, gives it a throwaway `HOME`,
runs it in its own process group with `stdin` closed and a 300s timeout, then `SIGKILL`s
that group so nothing survives to observe the token minted next. Only unstaged content
modifications of allowlisted tracked paths are accepted: untracked output, ignored output,
deletions, renames, type changes, file-mode flips, symlink substitution, index staging, and
any path outside the allowlist are rejected, and any rejection restores the tree and fails
the job before the mint step. Because `git status` reports nothing under `.git/`, the
validator also fingerprints the Git control surface of both checkouts — `config`,
`info/exclude`, every hook file with its executable bit, and `HEAD` — and requires it
byte-identical afterwards, so a hook cannot install a `pre-commit` or set `core.hooksPath`
and have it fire during the `git commit` that holds the token. That commit and push
additionally run with `core.hooksPath=/dev/null`. The hook is re-run
against its own output and must reach a fixed point, because releases get retried. The
release step then asserts the staged set is exactly the manifest plus the recorded
reconciled paths, and re-binds the pinned changelog engine to the contract SHA immediately
before executing it with the token.

An adopter that passes no `--reconcile-allow` gets a byte-identical caller and no step; the
generated contract test asserts that negative, so a hook cannot appear without review.
Closes [#1203](https://github.com/Verjson/.github/issues/1203) and unblocks
[Verjson/verjson-github-runner#195](https://github.com/Verjson/verjson-github-runner/issues/195).
Rationale and the full threat model are in
[ADR 0158](../docs/decisions/0158-pre-credential-release-reconciliation-hook/README.md).
