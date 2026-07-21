# Consolidate the AI merge gate into two runner jobs — 2026-07-21

Combine freshness with classification and AI review with merge so the required
gate uses at most two runner assignments and only one long CI wait. An immediate
head, hold, and CI recheck still fails closed before merge, with phase timing
diagnostics and extracted-shell regression coverage. See #104 and ADR 0017.
