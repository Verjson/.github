---
date: 2026-08-31
issue: 1213
impact: patch
title: Audit skips a stack that declares no required contexts
---

`scripts/required-checks-audit.sh` resolved a stack's core contract with a single
`jq -er '.stacks[$stack].contexts[]'`, which cannot distinguish a stack the
declaration never mentions from one it declares with an empty context list: both
produce no output and a non-zero exit. The `none` stack is the second kind, so an
unscoped run aborted at whichever `none` repository sorted first and reported no
per-repository results at all — the workaround being to compute the repository
selection out of band and pass it back through `RCA_REPOS`.

The declaration is now consulted for membership before the contexts are read. An
undeclared stack still faults; a declared stack with no required contexts is
reported as `result=skipped`, counted in a new `skipped=` tally on the
`phase=done` line, and the run continues.
