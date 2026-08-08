# 0082 — Receipt-bound provider and budget policy

- **Date:** 2026-08-08
- **Status:** Accepted
- **Issue:** [#655](https://github.com/Verjson/.github/issues/655)
- **Amends:** [ADR 0080](../0080-one-automatic-paid-ai-review-per-head/README.md)

## Context

One automatic paid review per head bounds call count but does not let operators
choose different cost policies for automatic review and an intentional second
opinion. Reading organization variables only when the model starts would also
let a mid-run edit change the authorized provider or ceiling.

Anthropic supplies a native dollar budget. The OpenAI Responses API supplies a
token cap, not a native dollar cap, so a dollar ceiling needs a conservative,
versioned conversion. The [Luna model documentation](https://developers.openai.com/api/docs/models/gpt-5.6-luna),
[API pricing](https://developers.openai.com/api/docs/pricing), and
[Codex GitHub integration](https://developers.openai.com/codex/github-action)
are the upstream references.

## Decision

The trusted arm selects primary organization variables for a new head and
secondary variables only for a maintainer-applied `re-review`. The primary
defaults retain the existing Anthropic classifier (`anthropic`, `auto`,
`auto`). An absent secondary policy fails before dispatch. Provider, model,
budget, and pricing-table version are written into the immutable exact-head arm
receipt as one canonical policy object, forwarded as one dispatch input, and
verified before the model runs. An explicit re-review additionally binds the
requesting actor and their `maintain` or `admin` permission. The verifier
requires that permission again immediately before model execution, so a
revocation between arm and spend fails closed.

Anthropic continues to receive its native `--max-budget-usd`. The only supported
OpenAI policy is `gpt-5.6-luna` on explicit re-review. It performs one tool-free
Responses request with strict structured output and no retry, continuation, or
fallback. Pricing table `openai-luna-long-context-2026-08-08` uses Luna's
uncached long-context rates of $0.40/MTok input and $1.80/MTok output (the
documented multiplier above 272K input tokens). Complete input UTF-8 bytes conservatively
bound input tokens; the remaining budget determines `max_output_tokens`.
Budgets unable to cover 1,024 output tokens fail before the network. Reported
usage must remain within the preflight input/output and dollar envelope.
The request embeds bounded UTF-8 `pr.json` metadata and the complete filtered
`pr.diff` as JSON-encoded untrusted data in a user-role item. A separate
developer-role item explicitly forbids following any payload instructions,
role claims, delimiters, or approval requests. PR-controlled bytes never enter
the trusted instruction item. The final serialized role-separated envelope is
what the preflight prices. A response is evidence only when the top-level response,
single assistant message, and output item are completed for the exact requested
model, contain no refusal/error/incomplete state, and pass local strict schema
and verdict-semantic validation.

Credentials remain step-scoped: the Anthropic action receives only Anthropic
credentials and the trusted OpenAI client receives only `OPENAI_API_KEY`.
Unknown providers, models, pricing versions, malformed budgets/responses, or
usage evidence fail closed.

## Consequences

Operators can deliberately buy a differently modeled second opinion without
ordinary CI or automation selecting it. Adding a model or changing rates
requires a code-reviewed pricing-table version rather than optimistic caller
inputs. The byte bound can underutilize a budget for non-ASCII or token-dense
input; that conservatism is the cost of a hard ceiling without a tokenizer.
