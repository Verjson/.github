---
date: 2026-09-17
id: 20260917T034500Z
title: Report a capped directory listing as its own gap kind
impact: patch
---

Review follow-up to #1373. The capped-listing gap was appended to `unreadable`,
whose members are paths whose blob could not be read and whose length is printed
as `unreadable_files=`. A capped directory is neither a path nor a file — the
file names themselves are what went missing — so one counter was reporting two
different conditions. It now has its own `incomplete_listings` list, its own
counter, and its own line, still folded into the non-zero exit. The entry is
printed one per line because it is the only gap that contains spaces, which
would otherwise break the space-joined "one token per gap" convention.

The test that covers the cap now also asserts the deliberate degradation: a
capped repository still contributes the entries it did return, so it appears in
the report with a gap rather than vanishing from it. The stubbed dispatch
matches `/contents/` rather than `contents`, which was one character away from
also matching the `.content` jq projection passed on the blob call.

The independent review of this change found four more paths in the same sweep
that reported a clean run over incomplete data, so they land with it. A blob
that failed to base64-decode was dropped without naming itself. `gh --jq
.content` prints the literal string `null` for the `encoding: none` shape
GitHub returns for an oversized blob, and that string is valid base64: it
decoded to three bytes of garbage which were then stored as real workflow text,
so the file contributed no pins and read as carrying no drift. A contents
listing that was not a JSON array — `{"message": "Not Found"}` — returned "no
workflows" rather than "unreachable", the exact conflation this function's
docstring forbids. And a truncated recursive hub tree collapsed into the same
`None` as an unresolvable ref: every row compared against a short tree is an
unsupported conclusion rather than an `UNKNOWN` observation, and it never
reached the exit code. Truncated trees are now their own named gap kind on the
same terms as capped listings.

The fold into the exit code had no test of its own, which meant the gap lists
could have been dropped from the predicate with every collection test still
green. It has one now, per gap kind.
