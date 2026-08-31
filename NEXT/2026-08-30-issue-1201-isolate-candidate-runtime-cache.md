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

Running against the real hosted `ubuntu-24.04` image surfaced a second, real defect: the
trusted-pwsh-discovery check required every ancestor of `/opt/microsoft/powershell/<ver>`
to be non-group/other-writable, but GitHub's hosted image ships `/opt` root-owned and
world-writable (mode 777, the same convention as `/opt/hostedtoolcache`) — so the check
could never pass against a real, untampered system `pwsh` on that runner class, breaking
the feature for every consumer. Fixed by trusting root ownership alone for the `/opt`
subtree, consistent with `/usr`'s existing unconditional trust elsewhere in the same
generator: nothing PR-controlled executes outside the sandbox before this check runs
(`npm ci --ignore-scripts` precedes it), so the writable bit is unexploited capability,
not evidence of tampering.

That first fix was incomplete: a second, shared ownership check further down in the same
tool-discovery loop (the generic `npm`/`node`/`pwsh` executable check, applied after
per-tool discovery) independently re-enforced the same write-bit requirement against the
resolved binary itself — and the real Microsoft-shipped `pwsh` binary under `/opt` is
*also* root-owned but world-writable there, not just its ancestor directories. Confirmed
by temporarily surfacing the failing path/uid/mode in CI before diagnosing. Fixed the
same way, scoped narrowly to a resolved `pwsh` executable under
`/opt/microsoft/powershell`; `npm`/`node` keep the strict write-bit requirement since
their trusted tool root (the setup-node cache) is not expected to be world-writable.

A third occurrence of the same requirement remained: `validate_root_owned_tool_tree`
recursively walks the whole mounted tool prefix and separately re-enforces the write-bit
on every directory and file entry underneath it, which still failed once the walk reached
the (also world-writable) contents of `/opt/microsoft/powershell/<ver>`. Gave that
function the same `require_unwritable` escape hatch, applied only when the tool prefix
being walked is the Microsoft PowerShell tree; every other trusted tool tree (including
npm/node's setup-node cache) keeps the original strict, unconditional check.

A fourth, structural (not permission-bit) issue surfaced once the write-bit relaxations
above cleared the walk: the real PowerShell 7 tree ships `libcrypto.so.1.0.0` and
`libssl.so.1.0.0` as symlinks to the host's system OpenSSL 1.0 compatibility libraries
under `/usr/lib64`, for distros that still carry them. The tool-tree walker rejected any
symlink whose target left the tool's own mounted prefix, so these legitimate compatibility
shims tripped the same "escapes mounted prefix" failure. Confirmed via a temporary listing
step in CI. Rather than loosen containment blanket-wide, an escaping symlink is now
re-validated against `/usr`'s own strict, unconditional trust (root-owned, non-writable
ancestry) before being allowed through; a symlink escaping anywhere else still fails
closed. `/usr` is unconditionally read-only bind-mounted into the sandbox regardless, so
this changes only the static verification, not the sandbox's actual exposure.
