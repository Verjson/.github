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

### Metadata support is a property of the immutable pin

The README describes the current contract, but consumers execute the engine at
their chosen immutable `contract_ref`. Published tag `v2.2.0` accepts only the
four base keys; it predates `refs`, `summary`, and `component`. No newer release tag
exists as of 2026-08-07, so do not infer current metadata support from
`v2.2.0`.

The migration guide recommends immutable commit
`d469f40db3b6c092e216910dc2a5eb0cfec6fa08`. Its engine accepts every key below:
<!-- recommended-contract-pin: d469f40db3b6c092e216910dc2a5eb0cfec6fa08 -->

<!-- contract-pin-metadata:start -->
| Metadata key | Required | Supported by `v2.2.0` | Supported by recommended pin |
| --- | --- | --- | --- |
| `date` | yes | yes | yes |
| `issue` | exactly one of `issue` / `id` | yes | yes |
| `id` | exactly one of `issue` / `id` | yes | yes |
| `title` | yes | yes | yes |
| `refs` | no | **no** | yes |
| `summary` | no | **no** | yes |
| `component` | no | **no** | yes |
| `impact` | no (defaults to `patch`) | **no** | yes |
<!-- contract-pin-metadata:end -->

`scripts/contract-pin.test.sh` executes the engine from that exact commit
against issue-form and id-form fragments carrying every advertised key. Adding
a key to this table without moving the recommended pin to an engine that
accepts it makes CI fail.

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
`summary` optionally overrides the lead paragraph used in a released snapshot;
it does not change the full running-log entry.

### Release impact

Every fragment may declare `impact: major`, `impact: minor`, or `impact: patch`.
An omitted impact explicitly defaults to `patch`, so existing fragments remain
valid. Impact is metadata only and never appears in rendered notes.

At release time the central engine computes the highest impact among the
selected fragments and requires the exact next SemVer version on that axis.
Ordinary SemVer rules apply before 1.0: `v0.4.2` advances to `v1.0.0` for major,
`v0.5.0` for minor, or `v0.4.3` for patch. Higher, lower, and skipped bumps fail
before any snapshot or fragment is mutated. The first release in a prefix stream
establishes its baseline.

Version prefixes define independent streams (`v1.2.3`, `python-v1.2.3`, and so
on). Component and explicit-fragment releases calculate impact only from their
selected fragments. Consumers pass versions and selectors to
`scripts/changelog.py`; they must not carry their own impact parser. See
[ADR 0067](../decisions/0067-changelog-impact-governs-version-bumps/README.md).

### Independent component streams

A repository that releases independently versioned packages may add an optional
component identifier:

```markdown
---
date: 2026-08-07
issue: 390
component: python
title: Add Python worker support
---
```

Component names are lowercase 1–64 character identifiers using letters,
digits, dot, underscore, and hyphen; they must start and end with a letter or
digit. They are stream names, not paths.

The default renderer and release select only fragments with no `component`, so
single-package repositories are unchanged and scoped work cannot leak into
their release. Preview or release one explicit stream with
`render-next --component python` or `release --component python`. An explicit
fragment list can narrow that stream but cannot select across component
boundaries. Validation and pull-request consumption checks still cover every
stream. See [ADR 0066](../decisions/0066-component-scoped-changelog-streams/README.md).

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
3. validates the requested version against the selected fragments' maximum impact;
4. refuses an existing snapshot;
5. writes exactly one snapshot and removes the selected fragments in the same
   commit;
6. tags that exact commit; and
7. regenerates `CHANGELOG.md` only as a display artifact.

Feature pull requests must not edit `CHANGELOG.md`, released snapshots, or
remove fragments. Release automation is the only fragment consumer.

Repositories should call the reusable
`.github/workflows/changelog-validate.yml` workflow and use
`.github/workflows/changelog-release.yml` for releases. Pin reusable workflows
to an immutable commit whose documented capabilities they need and pass that
same commit as the required `contract_ref` input. A release tag is convenient,
but it is not newer merely because `main` documents a feature; check the
capability table above.

### The release caller's `push_token`

Step 5 pushes the snapshot commit and its tag **directly to the default
branch**. Every Verjson repository carries an identical `main-protection`
ruleset whose `pull_request` and `workflows` rules forbid exactly that, and
whose only bypass actors are `OrganizationAdmin` and Renovate. `GITHUB_TOKEN`
is neither, so a release caller wiring it is rejected at the last step:

```
remote: error: GH013: Repository rule violations found for refs/heads/main.
remote: - Changes must be made through a pull request.
 ! [remote rejected] v0.4.0 -> v0.4.0 (atomic transaction failed)
```

Release callers must therefore pass an admin-scoped credential:

```yaml
    secrets:
      # NOT GITHUB_TOKEN — see Verjson/.github ADR 0052.
      push_token: ${{ secrets.ORG_ADMIN_TOKEN }}
```

The release caller must live at `.github/workflows/release.yml`. That path is
what `scripts/changelog-contract.test.sh` looks for, so a caller named anything
else silently loses both the pin check and the `push_token` check — it is
treated as an adopter that has nothing to release. Adopters with genuinely
nothing to publish have no such file, which is a supported shape.

The push is `--atomic`, so a rejected release leaves no tag, no snapshot, no
package and `NEXT/` untouched. It fails safely; it simply cannot succeed. The
trade-off is stated in ADR 0052: the release job holds a wider credential than
the repository-scoped default, which is why it must run only on explicit
dispatch and from the default branch.

### The release caller is generated, not copied

`--atomic` protects the *push*, not the release. Once that push lands, the
version is spent: re-dispatching it is refused because the tag exists, and
re-dispatching a higher one is refused with `release selected no fragments`
because `NEXT/` was already consumed. So anything that can fail must fail before
the push, and until #463/#464/#465 it did not — the caller was hand-copied from a
sibling, and its build, lint and test ran in a job that was `needs: snapshot`.

`scripts/gen-changelog-caller.sh release-node` emits the corrected shape:

```yaml
verify:   # default branch, version format, tag absence, and the full suite
snapshot: { needs: verify }   # the irreversible push
publish:  { needs: snapshot } # build and publish only
```

If your suite is not `npm test`, commit an executable `scripts/release-verify.sh`
and `verify` runs it instead. Do **not** edit the generated caller — the emitted
contract test asserts its provenance and rejects a hand-written one.

The defaults are npm scope `@verjson` and Node 24. A scaffolder targeting
another lowercase npm scope or numeric Node version passes the same validated
options to both coupled outputs:

```bash
scripts/gen-changelog-caller.sh release-node "$PIN" --scope @acme --node-version 22 > .github/workflows/release.yml
scripts/gen-changelog-caller.sh contract-test "$PIN" --scope @acme --node-version 22 > scripts/changelog-contract.test.sh
```

The generated contract test then rejects drift in either release job. Do not
generate only one side or edit the workflow after generation.

## Consumer adoption

A consumer needs three files, and they must pin the **same** commit — plus a
fourth if it publishes something. Generate all of them rather than writing them;
the reasoning is in the generator's header.

```bash
PIN=d469f40db3b6c092e216910dc2a5eb0cfec6fa08
# Changelog-only repositories keep the backwards-compatible caller:
scripts/gen-changelog-caller.sh workflow "$PIN" > .github/workflows/changelog.yml
# Repositories consolidating generated checks use this instead:
scripts/gen-changelog-caller.sh generated-artifacts "$PIN" > .github/workflows/changelog.yml
scripts/gen-changelog-caller.sh renderer "$PIN" > scripts/render-next.sh
scripts/gen-changelog-caller.sh contract-test "$PIN" > scripts/changelog-contract.test.sh
# Only if the repository publishes a Node package. Adopters with nothing to
# publish keep having no release caller at all.
scripts/gen-changelog-caller.sh release-node "$PIN" > .github/workflows/release.yml
chmod +x scripts/render-next.sh scripts/changelog-contract.test.sh
```

Choose exactly one workflow command. `generated-artifacts` enables changelog
validation but leaves ADR-index checking off. A repository with
`docs/decisions/` may opt into both checks only by acquiring the pinned
generator and generating the matching caller together:

```bash
scripts/gen-changelog-caller.sh adr-index-generator "$PIN" > scripts/gen-adr-index.sh
scripts/gen-changelog-caller.sh generated-artifacts-with-adr-index "$PIN" > .github/workflows/changelog.yml
chmod +x scripts/gen-adr-index.sh
```

`adr-index: true` without that generated script is deliberately a failure, not
a clean result. Do not copy the script from another repository or hand-edit the
caller: the generated contract test verifies that the script's digest matches
the same immutable pin as the caller.

Re-run all of them together whenever the pin moves, and commit the result — a
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

### Runner-preloaded cache

Generated renderers and contract tests also share one stable cache layout:

```text
VERJSON_CHANGELOG_TOOL_CACHE/<40-hex-contract-commit>/changelog.py
```

Runner bootstrap may preload that file to make validation and releases work
without egress. The path is only a discovery mechanism: generated artifacts
verify its bytes against the SHA-256 embedded for the exact pinned commit before
execution. Writable, restored, or partially populated caches receive no trust
from their location.

When the variable is unset, the same layout uses
`${XDG_CACHE_HOME:-$HOME/.cache}/verjson-changelog` as its root. A missing or
corrupt entry falls back to the immutable
`raw.githubusercontent.com/Verjson/.github/<commit>/scripts/changelog.py` URL,
verifies the temporary download, and atomically publishes it. If egress is
restricted and no valid preload exists, the error names the expected cache file,
digest, and cache-root setting. See
[ADR 0065](../decisions/0065-verified-changelog-tool-cache/README.md).

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
