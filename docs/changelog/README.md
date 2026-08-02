# Organization changelog contract

This contract is the canonical changelog policy for Verjson repositories.

## Unreleased changes

Ordinary pull requests add one independently authored Markdown fragment,
`NEXT/YYYY-MM-DD-issue-<identity>-<slug>.md`. The `-issue-` segment is a fixed
literal for every fragment; only the identity after it varies with the metadata
key:

```
NEXT/2026-07-30-issue-249-adopt-immutable-snapshots.md    # issue: 249
NEXT/2026-07-30-issue-20260730T184500Z-tidy-fixtures.md   # id: 20260730T184500Z
```

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

An entry may also carry `refs`, a comma-separated list of issue numbers it links
but does not own:

```markdown
---
date: 2026-07-30
id: 20260730T090000Z
refs: 13
title: Add authenticated public gateway transport
---
```

Identity must stay unique — that is what makes fragments conflict-free — so only
one entry per issue may carry `issue:`. Several entries can still be work on that
issue, and because only issue-form identities render a `#n` back-link, the rest
used to lose their release linkage silently. `refs` separates linkage from
ownership so every one of them links the issue. It renders after the identity:

```
_Date: 2026-07-30; id:20260730t090000z; refs #13_
```

`refs` is optional and additive: a fragment without it renders exactly as before.

The date and identity in the filename must match the metadata. Work that
legitimately has no issue uses `id` instead of `issue`; its identity must be a
UTC timestamp (`20260730T184500Z`) or a 6–12 character hexadecimal UUID prefix.
Only the metadata key changes — the filename keeps `-issue-`, so the inferred
`-id-` spelling is rejected as a non-canonical name. There is no sequential
fragment allocator. A second fragment with the same
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
all of them rather than writing them; the reasoning is in the generator's header.

```bash
ref=$(gh api repos/Verjson/.github/commits/main --jq .sha)
scripts/gen-changelog-caller.sh workflow "$ref" > .github/workflows/changelog.yml
scripts/gen-changelog-caller.sh renderer "$ref" > scripts/render-next.sh
scripts/gen-changelog-caller.sh contract-test "$ref" > scripts/changelog-contract.test.sh
chmod +x scripts/render-next.sh scripts/changelog-contract.test.sh
```

Re-run all three together whenever the pin moves, and commit the result — a
partial regeneration is the divergence the generator exists to prevent.

`scripts/render-next.sh` does not implement rendering. It fetches this
repository's `scripts/changelog.py` at the pinned commit, caches it by content
address under `$XDG_CACHE_HOME/verjson-changelog/<commit>`, and executes it. A
consumer therefore runs the same code locally that CI validates with, without
vendoring a copy that can drift — the failure `verjson-agents` demonstrated by
vendoring `changelog.py` and never receiving a later fix.

Consumers must not reimplement ordering, filtering, or filename validation. Four
independent bash renderers existed before this contract; one shipped a
locale-collated `sort -r` defect (`verjson-authn#93`).

`scripts/changelog-contract.test.sh` is the pin-agreement test — the renderer's
`CONTRACT_REF`, the workflow's `uses:` ref and its `contract_ref` input must be
one commit. Divergence there is silent: every file keeps working while local
output stops predicting CI.

**Do not hand-write or hand-edit that test.** It is the only adopter file that
encodes assumptions about repository *state*, and every hand-copied version so
far asserted a pre-release tree — named fragment titles, hashed released
entries, "no `CHANGELOG.md` yet", "released history is empty". A release
consumes `NEXT/`, writes `CHANGELOG/<version>.md` and generates `CHANGELOG.md`,
so each of those is false the moment the contract works as intended. Consumers
wire the suite into `npm test`, which release workflows run before publishing,
so the first dispatched release pushed its tag and then died in the publish job:
orphaned tag, nothing published, `main` red thereafter (#309). The generated
form derives every content assertion from the tree and is exercised against a
fixture that performs a real release.

## Where the engine is read from

Both generated scripts pin two things: the contract commit, and the SHA-256 of
`scripts/changelog.py` at that commit. Every path to the engine is checked against
that digest before it is executed — a cache hit, a fresh download, and an explicit
override alike.

The cache path is keyed by commit, which reads as content-addressed but is not.
Nothing prevents another tool, a restored CI cache, or an interrupted write from
leaving different bytes at that path, and before the digest was pinned those bytes
were executed as the contract on every subsequent run.

`CHANGELOG_CONTRACT_PATH` selects **where** the engine is read from:

```bash
CHANGELOG_CONTRACT_PATH=/opt/vendor/changelog.py scripts/render-next.sh
```

It is for a vendored copy, an offline mirror, or a warmed CI cache. It cannot
select **what** runs: an override whose bytes differ from the pinned digest is
refused, naming the pin it failed against. So the guarantee the renderer is sold
on — that it runs the same code CI validates with — holds regardless of the
environment, which is what makes the override safe to offer at all (#304).

## Repairing a released snapshot

`CHANGELOG/<version>.md` is immutable, and `check-pr` rejects **modifying** an
existing snapshot as well as adding one — so a malformed snapshot cannot be fixed
through an ordinary pull request. That is deliberate for released history, but it
also means a migration mistake (an inverted heading, or a snapshot for a release
that was never cut) would otherwise be permanent.

`check-pr` is a **pull-request** guard, not a filesystem lock. Repair is therefore
possible, and is defined as a deliberate maintainer act rather than a normal
change:

1. confirm the snapshot does **not** describe a real published release — check for
   a matching git tag and GitHub Release first. If one exists, the snapshot is
   correct history and must not be touched, however unusual its shape;
2. make the correction in a commit direct to the default branch, by a maintainer;
3. record it in an ADR, naming the snapshot and why it was not a real release.

Never repair a snapshot to make it *prettier*. Pre-contract releases legitimately
look different from generated ones, and rewriting them fabricates history that did
not happen — see the migration guide's step 2.

## Temporary migration compatibility

During issue [#249](https://github.com/Verjson/.github/issues/249), validation
and rendering may be given `--legacy-dir` for a former directory of unreleased
Markdown fragments. Compatibility is read-only: releases never consume legacy
fragments. Duplicate canonical/legacy issue identities still fail. The option
must be removed after the tracked consumer migration; it is not a second
unreleased store.

See [migration.md](migration.md) for the one-time conversion procedure.
