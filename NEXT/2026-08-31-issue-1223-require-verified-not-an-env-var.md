---
date: 2026-08-31
issue: 1223
impact: patch
title: require-verified is a positional flag, not an inheritable environment variable
---

`scripts/required-checks-audit.sh` read `RCA_REQUIRE_VERIFIED` as a plain
environment variable. A value exported by an unrelated parent shell, or
inherited across a CI step boundary, would silently flip the read-only
org-wide report to fail-closed with no caller ever having asked for that —
and the reverse is just as real: an ambient `RCA_REQUIRE_VERIFIED=true` could
mask `required-checks-rollout.sh`'s own explicit intent to require positive
verification before applying a rule.

The audit now takes `--require-verified` as a positional command-line flag
instead. It only takes effect when the invoking command line spells it out,
so nothing ambient can turn it on or off. An unrecognized argument faults
(`phase=startup result=unrecognized-argument`) rather than being silently
ignored, matching the old fail-closed intent for a caller typo.
`required-checks-rollout.sh` passes `--require-verified` on its `bash
"$AUDIT_SCRIPT"` invocation in place of the env-var prefix.

Found as an AI-review follow-up on PR #1222 (`scripts/required-checks-audit.sh:96`).
