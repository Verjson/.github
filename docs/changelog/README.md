# Organization changelog contract

This contract is the canonical changelog policy for Verjson repositories.

## Unreleased changes

Ordinary pull requests add one independently authored Markdown fragment:

`NEXT/YYYY-MM-DD-issue-<issue-number>-<slug>.md`

The fragment starts with YAML-style metadata understood by
`scripts/changelog.py`:

```markdown
---
date: 2026-07-30
issue: 249
title: Adopt immutable changelog snapshots
---

Describe the user-visible change and link its issue, ADR, and pull request when
applicable.
```

The date and issue identity in the filename must match the metadata. Work that
legitimately has no issue uses `id` instead of `issue`; its identity must be a
UTC timestamp (`20260730T184500Z`) or a 6–12 character hexadecimal UUID prefix.
There is no sequential fragment allocator. A second fragment with the same
issue or `id`, including one in a configured legacy directory, is rejected as
overlapping ownership and must be consolidated.

Rendering orders entries by metadata date, then stable identity and slug. File
allocation never determines precedence.

## Released changes

`CHANGELOG/<version>.md` is an immutable snapshot. A release:

1. acquires the repository release lock;
2. validates and selects canonical `NEXT/` fragments;
3. refuses an existing snapshot;
4. writes exactly one snapshot and removes the selected fragments in the same
   commit;
5. tags that exact commit; and
6. regenerates `CHANGELOG.md` only as a display artifact.

Feature pull requests must not edit `CHANGELOG.md`, released snapshots, or
remove fragments. Release automation is the only fragment consumer.

Repositories should call the reusable
`.github/workflows/changelog-validate.yml` workflow and use
`.github/workflows/changelog-release.yml` for releases. Pin reusable workflows
to an immutable organization release in consumers and pass that same commit as
the required `contract_ref` input.

## Consumer adoption

A consumer needs three files, and they must pin the **same** commit. Generate
them rather than writing them; the reasoning is in the generator's header.

```bash
ref=$(gh api repos/Verjson/.github/commits/main --jq .sha)
scripts/gen-changelog-caller.sh workflow "$ref" > .github/workflows/changelog.yml
scripts/gen-changelog-caller.sh renderer "$ref" > scripts/render-next.sh
scripts/gen-changelog-caller.sh contract-test "$ref" > scripts/changelog-contract.test.sh
chmod +x scripts/render-next.sh scripts/changelog-contract.test.sh
```

`scripts/render-next.sh` does not implement rendering. It fetches this
repository's `scripts/changelog.py` at the pinned commit, caches it by content
address under `$XDG_CACHE_HOME/verjson-changelog/<commit>`, and executes it. A
consumer therefore runs the same code locally that CI validates with, without
vendoring a copy that can drift — the failure `verjson-agents` demonstrated by
vendoring `changelog.py` and never receiving a later fix.

Consumers must not reimplement ordering, filtering, or filename validation. Four
independent bash renderers existed before this contract; one shipped a
locale-collated `sort -r` defect (`verjson-authn#93`).

## The contract test

`scripts/changelog-contract.test.sh` is generated, not adapted from another
repository's copy. It asserts that the tree validates, that the renderer, the
validation workflow and any release caller pin one commit, that every fragment
on disk renders with its metadata linkage, and that `CHANGELOG.md` equals the
contract's rendered release history.

Wire it into whatever the repository already runs — `npm test`, a CI step, a
Makefile target. Then leave it alone: regenerate it when the pin moves rather
than editing it.

Two properties are the reason it is generated rather than copied.

It is **release-safe**. A release consumes every `NEXT/` fragment, makes
`render-next` exit 1, and generates and commits `CHANGELOG.md`. A test that
names a fragment, renders unconditionally, or asserts that no aggregate
changelog exists is green until the first release and red permanently after —
in one adopter that test sat in `npm test`, so the first dispatched release
aborted after the snapshot commit and tag had already been pushed
([#309](https://github.com/Verjson/.github/issues/309)). Nothing here names a
fragment or a title, and every state assertion holds on both sides of a release.

It **cannot drift from the renderer**. Both scripts resolve the pinned contract
through the same emitted block, so they execute the same file by construction.
There is no `CHANGELOG_CONTRACT_PATH` override: an environment variable that
redirects execution to an arbitrary path reintroduces the vendored-copy drift
this contract exists to close, and the copied test that set one had been passing
only because the path it computed happened to equal the renderer's
([#304](https://github.com/Verjson/.github/issues/304)).

## Temporary migration compatibility

During issue [#249](https://github.com/Verjson/.github/issues/249), validation
and rendering may be given `--legacy-dir` for a former directory of unreleased
Markdown fragments. Compatibility is read-only: releases never consume legacy
fragments. Duplicate canonical/legacy issue identities still fail. The option
must be removed after the tracked consumer migration; it is not a second
unreleased store.

See [migration.md](migration.md) for the one-time conversion procedure.
