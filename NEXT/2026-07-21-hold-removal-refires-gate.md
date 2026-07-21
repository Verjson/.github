# Re-fire the merge gate when a terminal hold is removed — 2026-07-21

Subscribe the org merge gate to `unlabeled` events and narrowly re-run it when
`hold` or `DO NOT MERGE` is removed. This restores the documented hold/review
flow without running reviews—or cancelling an active review—for unrelated label
changes or the gate's own `re-review` cleanup. Closes #88; amends ADR 0012.
