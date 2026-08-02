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

A consumer needs two files, and they must pin the **same** commit. Generate
both rather than writing them; the reasoning is in the generator's header.

```bash
ref=$(gh api repos/Verjson/.github/commits/main --jq .sha)
scripts/gen-changelog-caller.sh workflow "$ref" > .github/workflows/changelog.yml
scripts/gen-changelog-caller.sh renderer "$ref" > scripts/render-next.sh
chmod +x scripts/render-next.sh
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

Add a repository-local test asserting the renderer's `CONTRACT_REF` equals the
workflow's `uses:` ref and its `contract_ref` input. Divergence there is silent:
both files keep working while local output stops predicting CI.

## Temporary migration compatibility

During issue [#249](https://github.com/Verjson/.github/issues/249), validation
and rendering may be given `--legacy-dir` for a former directory of unreleased
Markdown fragments. Compatibility is read-only: releases never consume legacy
fragments. Duplicate canonical/legacy issue identities still fail. The option
must be removed after the tracked consumer migration; it is not a second
unreleased store.

See [migration.md](migration.md) for the one-time conversion procedure.
