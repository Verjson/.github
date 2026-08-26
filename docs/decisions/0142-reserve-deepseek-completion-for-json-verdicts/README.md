# 0142 — Reserve DeepSeek completion for JSON verdicts

- **Date:** 2026-08-26
- **Issue:** [Verjson/.github#1110](https://github.com/Verjson/.github/issues/1110)
- **Category:** merge-gate AI review policy — **sensitive class**
- **Status:** Accepted
- **Amends:** [ADR 0090](../0090-human-first-opt-in-ai-review/README.md)
- **Supersedes:** ADR 0090's 2026-08-13 provider-local thinking-mode amendment

## Context

The merge gate asks DeepSeek for one tool-free JSON verdict. Thinking mode shares the
bounded completion with private reasoning that the gate cannot admit as a verdict. In
run `33002497981`, Pro produced reasoning without verdict content until the bounded
transport timeout, then Flash completed with an empty content string. Both exact-head
passes were correctly consumed without reusable evidence.

The gate needs a deterministic request policy that reserves the completion envelope
for the only accepted result: the JSON verdict. Provider tuning fields that apply to
reasoning mode do not strengthen that contract and can make the request internally
inconsistent.

## Decision

Every DeepSeek review request explicitly sets `thinking.type` to `disabled`, retains
JSON-object response mode, remains tool-free, and omits `reasoning_effort` and
`temperature`. This policy applies identically to Pro and Flash.

The stream parser rejects any non-empty `reasoning_content` even when the provider
accepts the non-thinking request. A successful stream still requires exactly the
requested model, one stopped assistant choice, a terminal marker, complete usage and
cache evidence, a budget-conformant cost, and non-empty schema-valid JSON verdict
content. Empty completed content remains a typed `json_decode` extraction failure with
content-free diagnostics.

Exact-head authorization, the cumulative two-pass cap, streaming bounds, immutable
pricing policy, provenance, replay retention, and fail-closed publication remain
unchanged.

## Consequences

- Output budget is available to the required JSON object instead of provider reasoning.
- Unexpected reasoning is evidence that the provider did not honor the reviewed request
  policy, so the pass fails closed rather than silently discarding it.
- Disabling reasoning may reduce depth on complex changes. The independent review gates
  and human path remain available; changing this provider policy requires another
  reviewed decision.

## Rollback

Disable DeepSeek selection while investigating provider compatibility. Do not restore
thinking mode without a new ADR that preserves bounded verdict production and the
existing exact-head and cost controls.
