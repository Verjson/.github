# Clarify ADR coverage for sensitive bug fixes — 2026-07-21

Document that sensitive-class fixes restoring an existing invariant must amend
the controlling ADR, while genuinely new or superseding decisions receive a new
ADR number. This resolves the merge-gate policy ambiguity without forcing a new
record for every corrective patch. Closes #76.
