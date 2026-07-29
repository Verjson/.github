# runs-on expression evaluator drops ambient Node authority — 2026-07-29

`runner-routing-policy.test.sh` evaluated the awk-extracted `runs-on` expression
through `new Function`, which runs with the full Node global scope. The input is
workflow text from this repository, so this was never a live privilege gain —
anyone able to edit those files can already edit the `.test.sh` that bash
executes outright. The concern is the pattern: evaluating extracted expressions
is a useful trick, and the next place it gets pointed may be a workflow from a
fork or another org.

Evaluation now happens in a `vm` context built from a null-prototype object, so
`process`, `require`, `fetch` and the module loader are absent by construction,
with a 5s timeout bounding a pathological expression instead of hanging CI. This
is hardening, not a security boundary — Node documents `vm` as not a sandbox
against hostile code.

Two probes pin it: evaluating `process.env.HOME` or `require("node:fs")` must
throw "not defined". Reverting to `new Function` makes both resolve, and the
suite fails.

Closes #187. Refs #184, ADR 0033.
