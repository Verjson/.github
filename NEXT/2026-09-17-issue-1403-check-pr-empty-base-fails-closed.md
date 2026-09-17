---
date: 2026-09-17
issue: 1403
title: Refuse a blank --base/--head instead of comparing HEAD against itself
impact: patch
---

`scripts/changelog.py check-pr --base '' --head HEAD` exited **0 silently**.
`git diff "...HEAD"` resolves a blank side to `HEAD`, so an empty `--base` made
the gate compare `HEAD` against itself: an empty diff satisfies every rule the
subcommand exists to enforce — no fragment requirement, no aggregate-edit
refusal, no fragment-consumption refusal. The ~95 adopter repositories that run
this gate would have been told their pull request was clean.

`validate` carried the same shape through a different mechanism. Its `--base` is
optional, and the dispatch tested it for truthiness (`if args.base`), so an
empty string was indistinguishable from omitting the option and the new-fragment
`impact` requirement was skipped entirely, also exiting 0. Omitting `--base`
stays the legitimate skip it has always been; the dispatch now distinguishes
`None` from blank.

Both now route through one `require_revision` guard that fails closed with a
stated reason rather than letting Git substitute `HEAD`. Whitespace-only values
previously surfaced a raw `git fatal: ambiguous argument` instead of a diagnosis,
and are covered by the same guard.

No canonical caller could reach this. Every generated `generated-artifacts.yml`
and `changelog-validate.yml` invocation already gates on
`[ -n "$BASE_SHA" ] && [ -n "$HEAD_SHA" ]`, and `BASE_SHA` is always populated on
a real `pull_request` event — verified against both workflows in this repository.
The fix is defensive: it removes a latent fail-open in a gate whose entire value
is failing closed, and it costs adopters nothing because no adopter passes a
blank revision today.

Control-tested both ways: the blank inputs must fail, and a pull request that
genuinely needs no fragment must still exit 0 with nothing on stdout or stderr —
including `validate` with `--base` omitted.
