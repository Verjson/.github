---
date: 2026-09-17
issue: 1410
impact: patch
title: Report the live ruleset fields no reviewed image pins
---

The authorization-arm audit's report now carries `unpinned_live_fields`: every
live field of a contracted ruleset that no reviewed image asserts, named by its
dotted path. The scheduled run therefore hands the periodic review ADR 0188
calls for its exact candidate set.

ADR 0188 tolerates keys GitHub adds so the comparison survives a vendor schema
that grows, and accepts as a residual that such a key is invisible by
construction — including one that weakens protection. Its stated mitigation is a
review with an owner that pins newly security-relevant fields. A review that
begins by re-reading a whole vendor schema by eye does not get done; this makes
it a diff of a short list. The decision itself is unchanged: an unpinned key is
reported, never treated as drift, because judging whether a new key matters
stays the reviewer's call rather than something the code asserts about itself.

The report covers the mutation payload and the top level beside it, because
`normalize_ruleset` keeps only the payload and a policy field GitHub adds
next to it would otherwise be invisible here too. Ruleset identity,
provenance, and timestamps are excluded as non-policy.

The candidate lookup fell back to the normalized live ruleset when a contracted
ruleset was absent from the organization listing. That object carries no
top-level key outside the compared set by construction, so its residual was
empty and the audit passed while silently reporting that the ruleset pins
everything — precisely when it could not be read at all, which is the silence
ADR 0188 rules out. An unreadable surface is now a failure naming the ruleset,
and the arm lookup raises the same typed error rather than `StopIteration`.
