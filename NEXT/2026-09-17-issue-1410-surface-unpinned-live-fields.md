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
