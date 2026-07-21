# Validate ADR index dates and both title separators — 2026-07-21

Reject malformed or impossible ADR `Date` metadata before generating the index,
including invalid leap days, and cover the supported plain-hyphen H1 separator
alongside the em dash. This keeps bad dates and unstripped numeric prefixes out
of the derived decision table. Closes #78 and #79.
