# Correct ADR 0015's PR cross-reference — 2026-07-20

ADR 0015 (gate retries a third time on the structured-output flake) landed via
PR #68, but its body cited PR #66 in two places (`- **PR:**` and the closing
"Full change:" link). Accurate ADR↔PR cross-linking is a stated convention (the
PR is the audit trail for the ADR's decision), so both references now point to
#68. Docs-only; no behaviour change.
