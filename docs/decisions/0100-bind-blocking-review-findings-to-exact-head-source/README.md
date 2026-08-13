# 0100 — Bind blocking review findings to exact-head source

- **Date:** 2026-08-13
- **Status:** Accepted
- **Issue:** [#773](https://github.com/Verjson/.github/issues/773)
- **Category:** merge-gate behaviour (sensitive class)
- **Extends:** [ADR 0079](../0079-head-bound-ai-authorization-and-native-auto-merge/README.md)

## Context

The provider-neutral verdict boundary validates structure and semantic
relationships, but it did not prove that a blocking claim described the cited
source. Two DeepSeek passes on one exact PR head copied text from nearby or
synthetic test lines into claims about production lines: one attributed
`git ls-remote --refs` to an annotated-tag verification command that did not use
that option, and one attributed an `ORG_ADMIN_TOKEN` mutation-fixture comment to
the changelog caller generator. Both schema-valid verdicts consumed the PR's
two-pass allowance and published source-contradicted findings.

The merge gate must reject findings that are not grounded in their cited line
without trying to decide whether a grounded finding's conclusion is correct.
That check must use the receipt-bound reviewed commit rather than a mutable
working-tree path, and an unusable verdict must not bypass the cumulative paid
review limit.

## Decision

Every blocking `findings` entry carries an `evidence` string copied from its
cited source line. The string is one line and at most 240 characters. It must be
at least eight characters when the source line permits; a shorter source line
requires its complete trimmed text. The canonical validator rejects missing,
multiline, oversized, trivial, or non-matching evidence.

A blocking finding location names exactly one repository-relative file and one
positive line. Ranges and comma-separated line lists are rejected rather than
collapsed to their first line. Historical normalization of those shapes remains
only for non-authorizing `review_first` inspection pointers and `followups`.

The validator receives the receipt-bound review head, requires it to equal the
checked-out `HEAD`, and reads `HEAD:path` through Git's object database. It
accepts only repository-relative paths and UTF-8 blobs, verifies the cited line
exists, and requires the evidence to be an exact substring of that line. Git
object reads avoid following PR-authored symlinks into runner files. Evidence is
HTML-escaped and published as code beside the finding so a reviewer can audit
the deterministic match without turning PR-controlled source into active
Markdown.

A mismatch makes the provider verdict unusable. The already-reserved pass still
counts. DeepSeek may take its one configured fallback only when the existing
PR-wide two-pass reservation guard allows it; no validator failure creates a
third invocation or App approval. Other providers retain their existing
single-pass behaviour. `review_first` inspection pointers and non-blocking
`followups` do not grant authorization, so this decision does not add evidence
fields to them.

The ordinary automatic allowance remains capped at two cumulative reservation
reviews. A maintainer or administrator may deliberately request one additional
diagnostic pass by applying the consumed `re-review` label. That authorization
is bound into the arm receipt and produces a distinct App-authored
`ai-review-explicit:v1` reservation marker. Explicit reservations count in
cumulative telemetry, bypass the ordinary cap for that one invocation, and
never trigger the DeepSeek fallback; every further diagnostic pass requires a
new authorized label event and receipt. The reservation guard also rejects a
second explicit marker for the same authorization check, so a fresh manual
dispatch cannot replay a still-open receipt even though its run attempt starts
at one.

GitHub may fail to create a `pull_request_target` run for a label event. Workflow
logic cannot repair an event it never receives. An operator may rerun an
existing arm attempt for the same exact PR head: the trusted arm re-reads the
current PR state, labels, hold state, actor policy, and head. When `re-review`
is currently applied, recovery resolves its latest label actor from issue-event
history, requires maintain/admin permission, binds that explicit authorization
into a new immutable receipt, and consumes the label after dispatch. This is a
recovery mechanism, not evidence that label delivery succeeded, and it does not
weaken model reservation limits.

## Consequences

- Nearby commands and synthetic mutation fixtures cannot substantiate a
  finding cited at another line.
- Source binding proves that quoted text exists at the reviewed head; the model
  reviewer remains responsible for semantic interpretation and severity.
- A provider may still choose a generic fragment present on the cited line.
  The minimum length reduces trivial matches without pretending that substring
  validation is semantic adjudication.
- Blocking verdict schemas and prompts change together for the Claude and
  OpenAI structured paths; DeepSeek receives the same canonical prompt and all
  providers converge through the shared validator.

## Verification

The registered merge-gate suite executes valid exact-head binding, the nearby
canary `--refs` confusion, the generator-versus-synthetic-fixture confusion,
range/list location rejection, head mismatch, unsafe paths, provider schema
conformance, publication rendering, edge-whitespace versus interior-token
matching, the unchanged one-to-two automatic reservation guard, the one-shot
explicit marker, and exact-head operator recovery after an absent label wake.
