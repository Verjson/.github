---
date: 2026-08-05
issue: 424
title: 'Tolerate unknown changelog metadata instead of rejecting it'
---

`validate_metadata` raised on any key outside `{date, issue, id, title, refs}`.
Because every repository pins its own contract SHA, that made each future
metadata addition breaking: a fragment carrying a new key failed validation in
every repository that had not bumped yet, and failed again if a repository ever
pinned backward with such fragments still in `NEXT/`.

Unknown keys now warn and are ignored. Measured against the previous contract on
the same `summary:`-bearing fragment: `rc=1` before, `rc=0` with a warning after.

This does not make existing pins tolerant — an older contract still rejects the
key. What it removes is the flag day for every *subsequent* field, so the
ordering requirement is paid once: repositories bump past this commit before any
fragment carries a new key.

The cost is stated rather than hidden. A typo in an **optional** key (`ref:` for
`refs:`) now degrades silently instead of failing, dropping a back-link, so the
warning names the offending key. Required keys are unaffected: `titel:` leaves
`title:` absent and still fails, because the checks test for the correct key's
presence rather than for the absence of a wrong one.

Tolerating a key is not honouring it — an unknown key contributes nothing to
rendered output, so an older contract cannot half-understand a newer fragment.

Prepares `summary:` (#426).
