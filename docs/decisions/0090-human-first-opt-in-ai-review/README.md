# 0090 — Keep human approval available when AI review is opted in

- **Date:** 2026-08-10
- **Status:** Accepted
- **Issue:** [Verjson/.github#732](https://github.com/Verjson/.github/issues/732)
- **Supersedes:** [ADR 0080](../0080-one-automatic-paid-ai-review-per-head/README.md)
- **Amends:** [ADR 0079](../0079-head-bound-ai-authorization-and-native-auto-merge/README.md), [ADR 0082](../0082-receipt-bound-provider-budget-policy/README.md)

## Context

The required AI workflow coupled merge availability to both its own implementation and
an external model provider. Run `31450341729` failed before review because trusted
classifier code referenced an unset shell variable. Repair PR #730 then needed an
administrator bootstrap because the broken workflow was its own required gate. After
that repair, run `31451246712` reached OpenAI but returned HTTP 429 without a verdict.
PR #727 had green deterministic CI and an independent review but remained blocked.

AI review can add evidence, but provider or workflow availability is not review
evidence. GitHub branch protection already requires current-head approval, CODEOWNERS,
resolved threads, linear history, and deterministic `shell-tests`. Those controls must
remain sufficient for an authorized human merge.

DeepSeek publishes an OpenAI-compatible Chat Completions API and JSON-output mode. Its
2026-08-10 price table lists, per million tokens, `deepseek-v4-pro` at $0.003625 cached
input, $0.435 cache-miss input, and $0.87 output; `deepseek-v4-flash` at $0.0028 cached
input, $0.14 cache-miss input, and $0.28 output. The table warns that rates may change,
so live pricing cannot be caller-controlled data.

## Decision

`AI_REVIEW_AUTHORITY` is an exact enum with safe default `human`:

- `human`: AI may post advisory comments but cannot approve or merge;
- `ai-approve`: a non-blocking opted-in verdict may mint the dedicated App approval;
- `ai-merge`: that exact App approval may also dispatch trusted terminal promotion.

Every unknown value fails before model spend. Authority joins provider, model, budgets,
pricing version, requesting actor, and permission in the immutable exact-head receipt.
The required workflow evaluates successfully when AI is skipped, blocking, rate-limited,
or inconclusive; none of those outcomes mints App approval. GitHub's ordinary human
approval rule therefore remains available in every mode. `hold`, `DO NOT MERGE`, draft,
stale-head, and malformed-policy checks remain terminal.

Model execution requires the normalized `ai-review` label or an explicit `re-review`.
The paid label requires maintain or admin permission. Later head events re-resolve the
label actor and current permission before creating another receipt; an unauthorized
label is removed when possible and remains fail-closed when cleanup fails. Unrequested
code uses the no-model human path. AI publishes comments only: even a blocking finding
never submits `CHANGES_REQUESTED`. Only the dedicated App may submit approval, and only
after the receipt grants `ai-approve` or `ai-merge`.

The `deepseek-v4-2026-08-10` policy permits exactly two passes: Pro with a $5.00 ceiling,
then Flash with its own $5.00 ceiling only when Pro produced no usable verdict. Any
usable blocking or non-blocking Pro verdict terminates the cascade; there is no third
automatic attempt. Complete serialized request bytes are conservatively priced as
cache-miss tokens before the call. Provider-reported cache hits, misses, prompt tokens,
completion tokens, exact model, single stopped choice, tool absence, and local verdict
semantics are validated after the call. Missing cache detail is priced entirely at the
cache-miss rate. A pricing change requires a new reviewed pricing-version allowlist.

`DEEPSEEK_API_KEY` is step-scoped and selected only for `Verjson/.github`. Generated
reusable callers declare the secret, but consumer repositories receive no organization
grant unless separately reviewed.

## Consequences

- Deterministic CI and human review can authorize merge during any AI outage.
- Model spend is opt-in, bounded to two separately capped calls, and receipt-auditable.
- `ai-approve` cannot dispatch merge; `human` cannot mint any App approval.
- Retry and privileged-promotion boundaries independently decode the receipt and reject
  terminal merge unless its authority is exactly `ai-merge`.
- AI findings are evidence for reviewers, not an unreviewable merge veto.
- Existing six-field receipt envelopes decode as legacy human authority during rollout;
  new nine-field envelopes bind authority and fallback policy explicitly.
- Enabling AI approval or merge is a sensitive organization-variable change and keeps a
  human-reviewed rollout and rollback gate.
