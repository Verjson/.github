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
