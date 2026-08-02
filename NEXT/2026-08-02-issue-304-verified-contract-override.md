---
date: 2026-08-02
issue: 304
title: Pin the engine digest, verify every path to it, and restore the contract override
---

The generated changelog scripts resolved the engine by path and executed whatever was
there. The cache path is keyed by a commit SHA, which reads as content-addressed but is
not: anything able to write it — another tool, a restored CI cache, an interrupted
download — became the contract for every later run. Demonstrated against the generator as
it stood, with a poisoned cache entry and no network: the renderer executed it and exited
0. With the digest pinned it exits 1 and names the pin it failed against.

Both generated scripts now carry the SHA-256 of `scripts/changelog.py` at the contract
commit and check a cache hit, a fresh fetch and an explicit override against it. A fetch
that does not match is refused *before* it is published into the cache, so a bad download
cannot be inherited.

That verification is what lets `CHANGELOG_CONTRACT_PATH` come back. #304 dropped it
because an environment variable redirecting execution made "runs the same code CI
validates with" conditional on the environment — the right call while nothing was
verified. Now the override selects only *where* the engine is read from (a vendored copy,
an offline mirror, a warmed CI cache) and cannot select *what* runs, so the air-gapped
consumer is served and the guarantee holds unconditionally.

The resolution logic is emitted from one function into both generated scripts rather than
maintained as two copies — two implementations of the code that decides which
implementation runs is the drift #304 reported, one level down.

One bug worth recording because the test suite is shaped around it: the first
implementation computed the pinned digest from `$(git show …)`, and command substitution
strips trailing newlines, so the digest described content the file does not have and every
honest override was rejected as divergent. The byte-identical-override case caught it
before it shipped, and now guards it.

The suite is hermetic. An earlier draft repaired the poisoned cache from the live network,
which only succeeds while the checked-out commit happens to be published — a rebase, a
fork, or an offline runner failed it for a reason unrelated to the behaviour under test.
Every fetch is now stubbed, and the whole suite passes with the network blocked.
