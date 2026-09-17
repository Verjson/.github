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
