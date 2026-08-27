---
date: 2026-08-26
issue: 1114
impact: minor
title: Restore absent secretless compatibility targets
---

Allow verified secretless compatibility artifacts to occupy an initially absent self-package target, then restore that absence after success, failure, or signal without adding a self-dependency pin.

Atomic no-replace placement and cleanup remain inode-bound, while consumer
execution resolves a read-only private package mount populated only from sealed
verified-archive bytes. Deterministic swap/load/restore races cannot substitute
attacker content, multi-lane swaps remain provenance-bound, and existing-target
behavior is unchanged under ADR 0146. The bubblewrap-dependent contracts run on
an explicit hosted Ubuntu 24.04 job whose result remains fail-closed under the
required `shell-tests` aggregate. Positive consumer-fixture failures now report
their exact return code and a fixed allowlisted sandbox-cause category. Raw and
unrecognized consumer stderr is always suppressed, so a missing or unusable
sandbox dependency remains distinguishable without exposing runner secrets.
Confirmed GitHub-hosted compatibility runs acquire bubblewrap only for an
eligible hosted compatibility execution, from signed Ubuntu apt metadata and
without credentials or broad upgrades. Package and executable version floors,
package ownership, root ownership, mode, and execution are verified before use;
self-hosted runners are left untouched. The hosted actions-ci contract mirrors
the production provisioner byte-for-byte and must run it first.

A subsequent hosted receipt reached verified bubblewrap but was denied an
unprivileged namespace by Ubuntu Noble's AppArmor policy. Eligible hosted
execution now also acquires signed `apparmor` and `apparmor-profiles`, verifies
their package floors, the absolute parser and restrictive package-profile
provenance, root identity and modes, plus capability-stripping profile
semantics. Local profile overrides are rejected before any policy load. A
credentialless unprivileged production-shaped probe is preferred; only its
failure permits that verified profile to load, after which the same
probe must pass. Sysctl relaxation, setuid, root bubblewrap, downloaded
profiles, and weaker fallbacks are forbidden; self-hosted runners stay
untouched.

The isolated, credentialless privileged loader recreates the exact receipt over
no-follow reads of package binaries, the structurally validated profile,
root-owned ancestors, and the complete AppArmor ABI and tunables include trees,
then executes the held parser descriptor against the held profile descriptor.
Set-id or
capability-bearing executables, unsafe include entries, local overrides,
misplaced profile transitions or denial, any other child capability rule,
working-directory Python import hijacks, and pathname reopenings fail closed
before the profile can load.

Filesystem failures now identify only a closed fixed phase:
`ancestor-directories`, `usrmerge-parser-link`, `local-overrides`, `abi-tree`,
`tunables-tree`, `bwrap-binary`, `parser-binary`, `package-profile`,
`profile-semantics`, `receipt-recomputation`, `profile-load`, or `unknown`.
The privileged loader maps fixed exit codes to those phases with all raw output
suppressed. The verifier shell accepts only an exact receipt or an exact
allowlisted diagnostic and maps all other producer/interpreter output to
`unknown`; exception text, dynamic paths, environment values, secrets, and
non-allowlisted sentinels cannot enter the diagnostic.

That shell boundary is byte-preserving: producer and interpreter output lands
in a private mode-0600 capture, and an isolated no-output validator requires
matching process status plus exactly one final newline. Trailing records, NUL
bytes, and status/content mismatches become `unknown`; raw and sanitized
captures are removed before emission and on failure or signal.
