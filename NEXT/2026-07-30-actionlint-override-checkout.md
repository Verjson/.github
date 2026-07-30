# Skip the central actionlint checkout for caller overrides — 2026-07-30

Reusable callers that provide `config-file` no longer pay for a redundant checkout of
the default central policy.

Closes #214.
