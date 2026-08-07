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
- [#477](https://github.com/Verjson/.github/issues/477) — the required-workflow rule makes the gate deaf to `ready_for_review`/`labeled`/`unlabeled` in **every** org repo (ADR 0063); `gate-rearm.yml` fixes only this one, the fleet still needs a generated caller.
- [#474](https://github.com/Verjson/.github/issues/474) — a fresh dry-run on 2026-08-07 finds 26 open org PRs missing the current `gate` context; 25 are eligible for ownership-routed retrigger and one is excluded. Requiring `gate` on `~ALL` remains blocked until the audit reaches zero.
- [#265](https://github.com/Verjson/.github/issues/265) — Org Actions secrets sit at `visibility: all`; scope them to least privilege.
- [#279](https://github.com/Verjson/.github/issues/279) — Attestation provenance: closed for the required-workflow shape (ADR 0044); open for the reusable-caller shape, which no repo uses yet.
- [#292](https://github.com/Verjson/.github/issues/292) — Re-review skip never fires: `gh api user` cannot resolve an identity under `github.token`, so every head change re-pays for an unchanged diff.
- [#437](https://github.com/Verjson/.github/issues/437) — `gen-changelog-caller.sh` emits only a `changelog-validate.yml` caller and its generated test greps for that string, so no adopter can move to `generated-artifacts.yml` without the hand-edit the contract forbids. Until it is fixed, tell adopters to stay put, and not to set `adr-index: true` without `scripts/gen-adr-index.sh`.
- [#454](https://github.com/Verjson/.github/issues/454) — `parse_frontmatter` (`scripts/changelog.py:90-97`) partitions every front-matter line on `:` and rejects any line without one, so a folded/literal scalar fails on its **continuation** line (`not separator`), not on the `summary: >-` line itself. Worse when there is no continuation: `>-` passes as a non-empty value and is stored as the literal string. Either way the key meant to hold a release note cannot hold one written the natural way; keep `summary:` on one line.
- [#585](https://github.com/Verjson/.github/issues/585) — `node-ci.yml` stops its optional database container before install/build/test steps, so DB-backed suites can lose the service before using it.

Prune an entry when its issue closes. This list loads into every session, so a
closed entry costs context in each one and misreports the state of the work.
