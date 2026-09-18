---
date: 2026-09-18
issue: 1445
impact: patch
title: Guard every early-exiting pipe consumer, not just `grep -q`
---

The `pipefail-sigpipe` guard now rejects any tracked shell script that pipes into a
consumer which stops reading early — `head` in every spelling, `grep -m`/`--max-count`,
and an `awk` program that calls `exit` — instead of `grep -q` alone, and twenty live
sites have been rewritten to read their first line without truncating a pipe.

`grep -q` was never the hazard #1430 diagnosed; *early exit on the read end of a pipe*
was. A consumer that leaves before the producer finishes gives it EPIPE, and under
`set -o pipefail` that becomes the pipeline's status — a confident, specific, false
assertion failure. The three sites #1445 named
(`scripts/ci-gate/changelog-validate-pin.test.sh`,
`scripts/ci-gate/changelog-contract-resolution.test.sh`, `scripts/repo-hygiene.sh`) were
latent only because their producers emit less than a pipe buffer, which is a property of
today's output size rather than of the code. The remedies keep the same result without a
truncated pipe: `IFS= read -r first < <(producer)`, a here-string where the producer was
already a shell variable, and a parameter expansion where the output was being clipped to
a byte budget.

`sed`'s `q` command is deliberately left out of the pattern and the omission is now
stated in the guard: no tracked script pipes into a quitting `sed` today, while a line
pattern cannot tell the `q` command from a `q` inside a replacement, so the arm would buy
a hypothetical catch with real false positives. Generated `run:` blocks under
`.github/workflows` remain out of scope for #1431's regeneration, as before.

Tracked as #1445, part of the #1430 family. (The closing keyword lives in the
pull request, not here: a fragment's prose can reach a release commit message.)

Two corrections from the independent review, before merge:

- The `|| var=''` fallback on each rewritten site discarded data rather than only
  absorbing a status. `read` returns 1 at EOF *while still assigning* the partial final
  line, so a producer emitting `abc` with no trailing newline yielded `abc` under the old
  `| head -n1` and an empty string under the replacement. Measured directly; every site
  now uses `|| true`. This was latent only because today's producers are `grep`/`awk` or
  GNU `sed` over newline-terminated files — a property of the inputs, not of the code,
  which is the reasoning this issue exists to reject.
- The `awk` arm cannot see a program written across real newlines, because
  `join_continuations` joins only lines ending in `|` or a backslash. One live site is
  missed today, so the twenty sites here are not the whole class. The ceiling is now
  stated in the guard and tracked in #1461, rather than left for a reader to infer from a
  green run. The same arm also matches an `exit` that is data rather than a statement;
  that direction is safe and is now stated too.
- The one semantic change this PR makes to `scripts/changelog-preview.sh` — the job-summary
  cap moving from `| head -c` to a parameter expansion — is now covered. Nothing exercised
  the truncation path before, so the cap and the notice that announces it could both have
  been dropped silently. Both directions redden now: removing the cap fails on the measured
  body length, removing the notice fails on its absence.
