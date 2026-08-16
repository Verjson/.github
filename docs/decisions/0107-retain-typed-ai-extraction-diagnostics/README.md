# 0107 — Retain typed AI extraction diagnostics without provider content

- **Date:** 2026-08-16
- **Status:** Accepted
- **Issue:** [#856](https://github.com/Verjson/.github/issues/856)
- **Related:** [ADR 0098](../0098-require-bounded-ai-review-for-code/README.md), [ADR 0105](../0105-preserve-ai-review-across-head-supersession/README.md)
- **Category:** AI merge gate / sensitive provider diagnostics

## Context

The synchronize canary on PR #854 proved that exact-head admission and deterministic
publication survived replacement of an older head. Both DeepSeek passes then completed
their SSE transports with terminal and usage evidence, but their short verdict contents
failed extraction. The provider client collapsed those failures into one redacted error
and wrote its replay bundle only after successful extraction. Operators could see byte
counts but could not distinguish malformed verdict JSON, response-envelope corruption,
invalid usage evidence, or another extraction invariant.

Retaining the response body would improve diagnosis at the cost of persisting untrusted
model output that can contain pull-request data, prompt fragments, or provider-generated
secrets. A diagnostic must remain useful without making that content an artifact or log.

## Decision

A completed DeepSeek response that fails extraction emits a trusted, typed cause:
`json_decode`, `response_shape`, `usage_envelope`, `tool_call`, or `verdict_shape`.
The diagnostic records only the content byte length and SHA-256 digest, plus the numeric
line, column, and position for JSON decoding failures. Raw verdict content, reasoning,
usage values, exception text, prompts, diffs, metadata, and credentials are never written
to the diagnostic output, logs, or artifact.

The client writes a bounded extraction-diagnostic artifact even though no replayable
verdict exists. It is explicitly non-authorizing and non-cacheable, bound to the exact
head, dedicated authorization check, repository, PR, pass, model, sensitive
classification, trusted workflow revision, and input digests. The staging helper accepts
only the closed schema and trusted cause vocabulary. Artifacts retain the existing
one-day diagnostic lifetime.

Deterministic publication validates the typed output against the same closed vocabulary
before naming the cause in its advisory. A malformed or absent diagnostic degrades to
the generic inconclusive wording. Extraction diagnostics never become verdicts, never
authorize approval or merge, and do not change the exact-head two-pass reservation cap.

## Consequences

- Operators can distinguish completed-response extraction failures without exposing
  provider content or secrets.
- A digest can correlate identical content across passes, but the artifact intentionally
  cannot replay or reconstruct the provider verdict.
- Both failed passes remain charged to the exact head; no diagnostic permits a third
  automatic provider invocation.
- Provider or artifact failures continue to leave deterministic CI and human approval
  available.

## Verification

`deepseek-review.test.py` completes Pro and Flash SSE fixtures before forcing JSON and
usage extraction failures, then proves typed diagnostics contain no sentinels.
`deepseek-replay.test.py` proves only a strictly provenance-bound, non-authorizing
diagnostic is staged. `review-comment.test.sh` executes the deterministic advisory and
proves a typed failure cannot submit a review. `ai-review-retry.test.sh` continues to
mutation-test the exact-head two-pass ceiling.
