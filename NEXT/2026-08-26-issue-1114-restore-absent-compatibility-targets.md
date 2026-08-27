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

The verifier now crosses no runner-owned pathname. A static root supervisor
hash-binds the trusted verifier source received on stdin, then executes those
immutable bytes from an isolated `-c` argument with stdin closed and classifies
the child's in-memory combined output. Only an exact status-and-byte receipt or
allowlisted
diagnostic is emitted; trailing records, NUL bytes, status/content mismatches,
outer failures, and every other value become fixed `unknown`. Concurrent
same-UID directory, raw-file, receipt-file, symlink, hardlink, and rewrite
attempts therefore have no artifact to substitute or leak through.

The exact hosted image then exposed a distinct boundary failure: its build
deliberately makes `/usr/share` recursively world-writable, covering both the
installed AppArmor profile and the image's default Ubuntu archive key path.
Eligible hosted execution no longer trusts either pathname or any global apt
source, list, cache, or configuration. A digest-bound root helper validates the
package-owned Ubuntu archive key under safe `/etc` ancestry, uses fixed Noble
archive/security sources with fresh isolated apt state and the verified system
dpkg status, disables global apt netrc and preference files and isolates their
parts directories, preserves `_apt` download sandboxing, and rejects unauthenticated,
weak, downgraded, stale, or TLS-invalid metadata.

The helper binds the exact `apparmor-profiles` version, architecture,
normalized repository filename, size, and SHA-256 to signed Packages metadata,
downloads exactly one matching basename into
an empty isolated cache, verifies its control fields, and streams one canonical
regular root-owned non-executable profile member. Structurally verified bytes
are atomically staged under a root-only non-writable `/run` hierarchy; the
world-writable installed profile is package-database evidence only and is never
read as trusted content. Archive/member ambiguity, links, unsafe metadata,
content or receipt drift, unexpected staged entries, and identity changes fail
closed. The acquisition session is identity-bound and removed on success,
failure, or handled signal; an uncommitted stage is also removed, and cleanup
failure emits only the fixed `package-profile-cleanup` phase.

The exact embedded helper now has an import-safe `main()` guard and a registered
behavioral contract that runs its byte-identical node/actions functions through
golden and failing OS/subprocess fixtures, including full acquisition
orchestration, metadata and filename rejection, archive/member validation,
staging, signals, cleanup, and supervisor output suppression. `SyntaxWarning`
is fatal for both production source and every coordinated mutation.

Acquisition failures now report one of ten fixed, secretless
`package-acquisition-*` phases covering key validation, apt update, bounded
plan, install, installed status, signed metadata, download, archive, member,
and staging. Child, digest-bound supervisor, and outer shell require exact
diagnostic/status pairs (83–92); cleanup remains 82 and every unknown,
cross-paired, trailing, NUL, raw, timeout, or interpreter result becomes fixed
`unknown` status 81. Staging compares archive and staged files by the full
device/inode pair, allowing equal inode numbers on different devices but
rejecting the same underlying file.

The hosted `package-acquisition-metadata` receipt was traced to an unrelated
Universe `Provides` record whose 70,841-byte line correctly exceeded the
65,536-byte Packages parser bound. Signed metadata enumeration now selects
exactly `Component: main`, where `apparmor-profiles` is published, while the
fixed apt sources still include Universe for package resolution. Exact
selector ordering, unique prefixed regular index paths, metadata fields,
`_all.deb` naming, and the existing per-line and total bounds remain enforced.
