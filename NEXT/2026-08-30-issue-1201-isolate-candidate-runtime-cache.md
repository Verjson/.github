---
date: 2026-08-30
issue: 1201
impact: patch
title: Isolate each protected candidate script runtime cache
---

Run every candidate script in a verified Bubblewrap mount and PID namespace with a
minimal read-only system runtime and a fresh bounded, digest-verified cache copy, then clean it
on completion, failure, or interruption so one script cannot mutate another script's
dependency evidence or leave detached descendants.

The candidate namespace exposes neither host control sockets/devices nor confidential
host trees and has no network. Networked service-container canaries remain a separate
admitted workflow contract.

The generated protected workflow keeps credential variables absent, anchors tool discovery to
the canonical setup-node cache with root-owned full-tree checks and descriptor-bound read-only
mounts, rejects runner-owned mutable tool caches and in-place content mutation, verifies and mounts
the versioned root-owned Microsoft PowerShell runtime, and rejects PATH shadowing, tool-prefix swaps,
lexical workspace aliases, and unsafe or oversized cache inventories,
and leaves the legacy reusable Node workflow byte-identical.

`node-ci-required-identity.test.py`'s namespace-execution tests moved from the shared
`platform` script group to the `hosted-compatibility-tests` job: the persistent fleet
runner that backs `platform` does not carry a Bubblewrap host dependency by design (see
`.github/workflows/actions-ci.yml`'s `hosted-compatibility-tests` comment), so the tests
failed there with "verified bubblewrap namespace boundary is unavailable" while passing
against the job that actually provisions a verified sandbox.
