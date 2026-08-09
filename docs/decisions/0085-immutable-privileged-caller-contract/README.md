# 0085 — Pin privileged callers to immutable contract revisions

- **Date:** 2026-08-09
- **Issue:** [Verjson/.github#676](https://github.com/Verjson/.github/issues/676)
- **Supersedes:** ADR 0042's `@main` exception for privileged callers
- **Extends:** ADR 0043's runtime canonical-revision verification
- **Category:** merge authority / org admin token — **sensitive class**

## Context

Privileged callers grant the canonical workflow a terminal merge credential. ADR 0042
made those callers the sole organization exception to immutable workflow pins so every
consumer would float with `Verjson/.github@main`. The runtime guard added by ADR 0043
already rejects canonical revisions that are not reachable from `main`, but a mutable
caller ref still prevents a reviewer from proving which contract the reviewed consumer
will execute after merge.

The organization rollout requires generated artifacts to name one immutable contract
revision. Consumer migration is tracked and supervised, so security corrections advance
through explicit generated pull requests rather than an unreviewed mutable ref.

## Decision

`scripts/gen-privileged-merge-caller.sh` requires a lowercase 40-hex contract SHA and
emits the exact canonical workflow path at that SHA. It rejects missing, mutable, short,
or non-canonical refs before emitting YAML. The generated regeneration comment records
the same SHA and optional runner selector so the artifact is reproducible.

The runtime ADR 0043 guard remains in force. An immutable revision must still belong to
`Verjson/.github` and be reachable from canonical `main`; a SHA is content identity, not
independent authorization. Generated consumers omit `runner_labels` in Verjson so the
programmatically resolved privileged organization policy remains authoritative.

## Consequences

- Reviewers and conformance checks can bind each consumer to exact reviewed content.
- Canonical security fixes require tracked regeneration across managed consumers.
- Repository administrators can retain an older main-reachable revision until
  conformance detects drift; rollout supervision and admission reconciliation own that
  residual risk.
- External self-hosted consumers may still provide a validated explicit runner selector,
  but they must also choose an immutable canonical contract SHA.

## Rollback

Revert the implementing pull request to restore the ADR 0042 `@main` generator. Existing
SHA-pinned callers continue to execute because ADR 0043 accepts canonical revisions
reachable from `main`; rollback does not require an emergency consumer rewrite.
