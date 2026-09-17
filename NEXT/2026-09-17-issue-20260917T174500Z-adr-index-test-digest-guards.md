---
date: 2026-09-17
id: 20260917T174500Z
title: A digest pin now fails closed instead of pinning the empty-string hash
impact: patch
---

`scripts/gen-changelog-caller.sh` computed `ADR_INDEX_SHA256` and
`ADR_INDEX_TEST_SHA256` by piping a resolver into `digest_of`, so a resolver
that refused produced an empty stream and pinned `e3b0c442…`, the SHA-256 of
nothing. No adopter file can ever match that digest, which made the emitted
contract test unsatisfiable while the generator's own `[ -n … ]` guards looked
satisfied. Both pins now go through `digest_of_resolved`, which requires the
resolver to exit zero, write a non-empty file, and yield a non-empty digest,
and reports the resolver's stderr when it does not.

The `adr-index-test` dispatch read its status through `if ! out="$(…)"`, which
inverted the value being captured and turned a documented status-3 refusal into
a silent exit 0. It now captures the status on the failure branch itself.

`scripts/ci-gate/changelog-caller-contract.test.sh` asserts both behaviors
against a fixture commit whose rewrite anchor is removed: the refusal must
carry status 3 and its stated reason, an unresolvable suite must pin nothing
rather than the empty digest, and each pin must digest the bytes its own mode
writes to disk. The fixture is built with git plumbing into a scratch object
store so the suite neither touches the working tree nor leaves objects behind.

Follow-up hardening on the `adr-index-test` mode introduced for `#1380`.

That fixture resolved the real object store with `rev-parse --absolute-git-dir`,
which in a linked worktree names the worktree's private git directory — a path
with no `objects` under it. The alternate therefore pointed nowhere, the fixture
could not be staged, and every assertion that consumes it reported its own
unrelated failure, so the suite blamed the refusal branch for a staging fault.
It now uses `rev-parse --path-format=absolute --git-common-dir`, the idiom the
rest of `scripts/` already uses.

That was only the local symptom. On a CI runner the staging step always
succeeded, and the fixture failed one step later: `git commit-tree` refuses
without a committer identity, which a runner's checkout does not configure, so
it died with `unable to auto-detect email address` and yielded an empty ref. The
generator then refused that empty ref on *ref validation*, and the suite reported
the refusal branch as misbehaving. The identity is now supplied through the
environment, needing nothing of the host and leaving nothing behind.

Both faults shared one shape worth naming: a fixture built by several plumbing
commands checked only the first one's status, so a failure in any later command
was reported as a misbehavior of the branch under test. Each construction step is
now checked, and the assertions that consume the fixture are skipped rather than
run against an empty ref.

A resolver can also succeed and yield nothing at all — an empty blob at the ref,
or a 200 with an empty body. `emit_adr_index_generator` turned that into a lone
newline, which is non-empty enough to satisfy `digest_of_resolved` and would pin
a real-looking digest over a one-byte generator, and the `adr-index-generator`
mode bypassed that emitter entirely, so the mode and its pin could disagree
about what an adopter must have on disk. The emitter now refuses empty content
and the mode goes through it. The pin-agreement assertions capture each mode's
status and require it to have written bytes, because a mode that emits nothing
otherwise makes the pin agree with itself.

Resolving that fixture's object store assigned through `export`, which reports
export's own status and never the command's, so a failed `rev-parse` would have
left the bare path `/objects` behind and turned this coverage into a silent skip
rather than a diagnosed failure. The status is now taken from the command.
