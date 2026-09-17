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
