---
date: 2026-08-06
issue: 443
title: 'fix(changelog): the generated renderer accepts --as-released'
---

`scripts/render-next.sh --as-released` now works in an adopter repository
instead of exiting 2.

The released form is what a release writes into `CHANGELOG/<version>.md`, which
under ADR 0059 can never be corrected afterwards, so reading it before merge is
the one review step the contract asks of a fragment author. #426 added the flag
to the engine and told authors to use it, but the renderer they are given
refused every argument — leaving them to skip the review or hand-edit a
generated artifact, and the contract forbids the second.

Only `--as-released` passes through. Anything else is still refused, because
this is a renderer, not a general front end to a pinned engine: forwarding
arbitrary arguments would let a caller reach subcommands the contract does not
sanction, `release` among them.

Reported by the `verjson-observability` PM, who found that the required review
step could not be run with the tooling shipped alongside it.
