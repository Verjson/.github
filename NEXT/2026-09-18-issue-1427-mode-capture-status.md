---
date: 2026-09-18
issue: 1427
title: Name the generator mode that refused instead of blaming its empty capture
impact: patch
---

`changelog-caller-contract.test.sh` captured each generator mode with
`var="$(bash "$gen" <mode> "$sha")"`, which discards the generator's exit status. A mode
that refused therefore left an empty capture, and the assertions downstream read that
emptiness as a defect in the thing they test: a single
`FAIL - adr-index-test did not rewrite the repository root for the adopter layout` at a run
whose rewrite logic was correct, while six reruns of the identical tree were clean. That
verdict sends the next reader to the rewrite, which works, rather than to the resolution
failure, which does not.

Each top-level mode capture now takes its own status and, on a nonzero one, fails with that
mode's own stderr — the pattern the file already uses for `rev-parse --git-common-dir`.
Because every later assertion consumes one of those captures, a capture failure stops the
suite rather than burying the one named cause under a page of unrelated empty-string
verdicts. The generator's usage text keeps its deliberate `|| :`: refusing a missing mode is
what that capture asserts.

The suite already failed closed, so this changes diagnosability, not what it accepts.
