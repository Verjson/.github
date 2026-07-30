# Harden runner-lane migration seams — 2026-07-30

Merge-gate preflight now stays on the untrusted lane until target visibility is
resolved, and admission reconciliation accepts both compatibility and namespaced lane
labels.

Closes #225 and #226. Refs ADR 0035.
