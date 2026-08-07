---
date: 2026-08-07
title: Prune closed issues from the CLAUDE.md Active Issues list
id: 20260807T040000Z
---

`CLAUDE.md` loads into every session, so a closed entry in `Active Issues` costs context in
each one *and* misreports the state of the work — which is what that list's own closing
instruction exists to prevent. Five entries closed today are removed: #263, #312, #399, #412
and #482.

Also re-pointed the transient-5xx entry from #490 to
[#394](https://github.com/Verjson/.github/issues/394). #490 was a duplicate I filed without
finding the prior art; #394 states the class more generally and now carries the evidence from
all four call sites plus an implementation brief.

Issue-less by nature — housekeeping with no ticket — so this fragment carries an `id:` UTC
timestamp identity rather than an `issue:` number or a shared sequence.
