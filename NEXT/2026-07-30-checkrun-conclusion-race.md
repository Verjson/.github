# Wait for completed check conclusions — 2026-07-30

Keep the merge gate fail-closed without rejecting healthy CI when GitHub briefly reports a completed CheckRun before populating its conclusion. The polling gate waits for the conclusion, while the immutable merge recheck refuses the inconclusive snapshot. See #240 and ADR 0024.

ADR 0036 also records the bounded recovery used when the repository's disabled Actions-review-approval policy prevented this sensitive workflow fix from obtaining a green gate. The permission remains disabled by default; #242 tracks the permanent audit-comment fallback.
