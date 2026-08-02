# Verjson/.github — repo working notes

Org-level `.github`: the merge gate (`ai-review-merge.yml`), reusable workflows
(`helm-ci`/`pulumi-ci`/`ui-ci`), composite actions, and decision records. These
conventions augment the workspace and global `~/.claude` rules; where they
conflict, the more local one wins.

## Running log — add a NEXT/ fragment, never edit a shared file

This repo does **not** keep a prepend-only `NEXT.md`. In the same commit as a
change that affects behaviour, pins, docs, or config, add a **new** file
`NEXT/YYYY-MM-DD-issue-<issue-number>-<slug>.md` (see `NEXT/README.md` for
metadata and the issue-less exception).
Because no two PRs touch the same file, the log can't produce merge conflicts —
which is the whole point. Read the log with `scripts/render-next.sh`. `NEXT.md` is
a static pointer; don't add entries to it.

## ADRs — add a directory, let the index generate

Decisions live at `docs/decisions/NNNN-<slug>/README.md` with a `# NNNN — Title`
H1 and a `- **Date:** YYYY-MM-DD` line. **Do not hand-edit the index table** in
`docs/decisions/README.md` — run `scripts/gen-adr-index.sh` to regenerate it from
the ADR directories, and commit that. `actions-ci` runs `gen-adr-index.sh --check`
and fails if the committed table is stale. On a rebase, re-run the generator
instead of hand-merging table rows. Sensitive-class changes (auth/RBAC, rulesets,
runner topology, IAM/OIDC, secrets, merge-gate behaviour) still require an ADR.
For a bug fix that restores an invariant already recorded in an ADR, amend that
controlling ADR with the dated rationale and evidence; reserve a new ADR number
for a new or superseding decision. “Restoring intended behaviour” is not an
exemption from decision-record coverage.

## CI-gate tests

The gate's shell logic is unit-tested by extraction — `scripts/ci-gate/*.test.sh`
awk-extract the exact `run:` block from `ai-review-merge.yml` (single source of
truth) and exercise it against a stubbed `gh`. Add/extend a test for any gate
change, and wire it into `actions-ci.yml` (a test that isn't wired there does not
run — that gap once left the `hold.test.sh` pin dormant).

## Autonomous batches — review before the gate merges

The org self-gate AI-reviews and **auto-merges on green in ~1–3 min**, so it will
merge a PR before an out-of-band `code-reviewer` pass finishes. When landing
non-trivial or fanned-out work autonomously:

- Run the independent `code-reviewer` **before pushing**, or open the PR as a
  **draft** (the gate skips drafts) / apply the **`hold`** label until the review
  passes, then mark ready / remove `hold`. `DO NOT MERGE`/`hold` are honored as
  terminal holds (ADR 0012).
- Worktree agents may be cut from a **stale** base — fetch real `origin/main` and
  branch from it before working, and keep local `main` synced after squash-merges
  (remote is the source of truth; local `main` goes stale).
- PRs that touch shared append surfaces are conflict-prone when run in parallel;
  the `NEXT/` fragments + generated ADR index above remove the common cases.

## Active Issues / Areas for Improvement

- [#261](https://github.com/Verjson/.github/issues/261) — Bind privileged-merge provenance to a signed workflow identity; the durable closure for #279's residual.
- [#263](https://github.com/Verjson/.github/issues/263) — Draft-time gate skip is terminal: the PR can never satisfy the merge gate without a new head SHA or a close/reopen.
- [#265](https://github.com/Verjson/.github/issues/265) — Org Actions secrets sit at `visibility: all`; scope them to least privilege.
- [#279](https://github.com/Verjson/.github/issues/279) — Attestation provenance: closed for the required-workflow shape (ADR 0044); open for the reusable-caller shape, which no repo uses yet.
- [#281](https://github.com/Verjson/.github/issues/281) — ADR 0028 decision 6 (public merge gate on hosted) has lapsed with no superseding decision.
- [#292](https://github.com/Verjson/.github/issues/292) — Re-review skip never fires: `gh api user` cannot resolve an identity under `github.token`, so every head change re-pays for an unchanged diff.
- [#300](https://github.com/Verjson/.github/issues/300) — `v2.1.1` was promised by ADR 0014 and never cut, so the documented exact pin lacks the #164 eligibility fix.
- [#303](https://github.com/Verjson/.github/issues/303) — `ai-review-merge.yml` has no `workflow_files_changed` guard on its own direct merge path; ADR 0044 depends on that guard.
- [#312](https://github.com/Verjson/.github/issues/312) — `ref_is_immutable` accepts abbreviated SHAs; no test covers it.
- [#317](https://github.com/Verjson/.github/issues/317) — Snapshot repair is documented and pre-contract snapshots accepted; open only for the `verjson-agents` repair (tracked in `Verjson/verjson-agents#151`).

Prune an entry when its issue closes. This list loads into every session, so a
closed entry costs context in each one and misreports the state of the work.
