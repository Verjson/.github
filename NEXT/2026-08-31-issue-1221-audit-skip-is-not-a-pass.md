---
date: 2026-08-31
issue: 1221
impact: patch
title: A skipped repository is not a pass for a caller about to apply a rule
---

`scripts/required-checks-audit.sh` skips a repository whose stack declares no
required contexts and still exits 0. That is right for the org-wide report,
whose question is "which repositories would be wedged?" — a stack that requires
nothing cannot be.

It was wrong for `scripts/required-checks-rollout.sh`, whose only conformance
gate is that exit status. The rollout selects repositories by the ruleset's own
`repository_properties` rather than by `verjson-stack`, so a contextless stack
can sit inside the set it is about to gate. `verjson-agents` does today: it
carries `changelog-contract=adopted` and `verjson-stack=none`. The rollout would
therefore have required `changelog / validate` on a repository the audit never
confirmed emits it, which is the permanent-pending wedge the audit exists to
prevent.

The audit now takes `RCA_REQUIRE_VERIFIED`. Left at its default of `false`
nothing changes. The rollout sets it to `true`, which turns a skip into an
annotated `result=unverifiable` error and a non-zero exit, so the caller that is
one API call away from a mutation asks for positive verification instead of
settling for the absence of a complaint.

Two related boundary defects go with it. `core_contract_for`'s second `jq` call
had no `|| fault`, so a malformed declaration exited 2 with a raw
`jq: error … Cannot iterate over null` and no `::error::phase=` annotation at
all — fail-closed, but invisible in Actions and mislabelled by the rollout as
repository nonconformance. And the startup schema validated `.stacks` as an
object without validating any stack's `contexts`, so `{}`, `[""]` and `["", ""]`
all reached the audit and read as "requires nothing", because command
substitution strips empty lines. Every stack's `contexts` is now validated at the
declaration boundary as an array of literal check names.

"Non-empty" is not the right predicate there, because the consumer is a shell
`read`. A context of `"   "` is non-empty to jq and empty to `read`, so it would
resolve to a non-empty contract that then checks nothing and reports the
repository conformant — the same "verified nothing, called it a pass" outcome
one level down, at per-context granularity. Surrounding whitespace is rejected
for the same reason, since `read` would otherwise compare a different string than
the one declared, and tabs and newlines because a context carrying one splits in
two. The reader itself now uses `IFS= read` as well; that is defence in depth
behind the schema rather than a separately reachable path.

The exit gate gains the matching positive requirement. Every other clause counts
what went wrong, so an audit that examined no repository at all satisfied all of
them and exited 0. That stays a fair answer for the org-wide report, but under
`RCA_REQUIRE_VERIFIED` at least one repository must have been confirmed
conformant, so an applying caller cannot read an empty run as verification.
`RCA_REQUIRE_VERIFIED=` set to the empty string now faults rather than taking the
permissive default: an empty value is a caller mistake, not a request to relax.

The controlling decision record, ADR 0058, carries a dated amendment for this:
the audit is the only conformance gate in front of a branch-protection write, so
"nothing complained" was never verification.
