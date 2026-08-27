# 0146 — Restore absent secretless compatibility targets

- **Status:** Accepted
- **Date:** 2026-08-26
- **Amends:** [ADR 0141](../0141-swap-verified-compatibility-packages-without-graph-resolution/README.md)
- **Category:** Security-sensitive (credentialless package-swap boundary)
- **Issue:** [#1114](https://github.com/Verjson/.github/issues/1114)

## Context

The canonical secretless compatibility lane swaps a provenance-verified published
package into an installed consumer graph without registry access. ADR 0141 required the
target package directory to exist first. A package testing its own published baseline
correctly has no self-dependency, so its scoped `node_modules` parent can exist while the
exact self-package target does not. Requiring a self-dependency would manufacture a
retention-sensitive package pin and change the graph being tested.

Letting an absent target through without tracking its initial state would leave the
published package behind after the lane. Following a symlinked or replaced parent could
write the verified artifact outside the installed graph, while treating a target that
appears during staging as the expected absence would overwrite unverified state.

## Decision

Permit only the final compatibility package target to be initially absent. Open and hold
every existing parent component from `node_modules` to the package parent as a real
directory with no symlink following, reject path components that can escape that chain,
and revalidate the held parent identity before staging, swapping, and cleanup.

Record whether the exact target was absent before any staging. The first lane may occupy
that absence only if the target is still absent; later lanes may replace only the exact
directory identity installed by the preceding verified lane. A symlink, non-directory,
missing or replaced parent, changed staged target, or independently appearing target
fails closed before consumer execution.

Keep the verified staging directory descriptor open through placement and use Linux
`renameat2(RENAME_NOREPLACE)` for the transition into the held package parent. The placed
name must resolve to the staged inode before consumer execution, and the same open inode
must remain at that name after execution. Competing target, staging-name, parent, or
post-execution identity changes fail without deleting the competing entry.

Do not let `npm run` resolve the mutable installed pathname. Require the trusted,
root-owned `/usr/bin/bwrap`; an absent or writable executable fails closed. For
each lane, derive a private package projection directly from the verified archive
bytes: every regular file is copied through a sealed anonymous `memfd`, the
package is assembled on private tmpfs inside fresh user, PID, IPC, UTS, and
cgroup namespaces, and the package mount is remounted read-only. The sandbox
drops all capabilities and disables nested user namespaces before it runs the
consumer script. The archive and provenance paths exposed to that script are
separate sealed anonymous files in the same private mount. Its workspace and
`node_modules` path topology are private, so
an earlier PR-authored background process can rename, load, and restore the host
target without changing which package bytes the consumer resolves. The external
installed target remains only the state whose placement and restoration the lane
audits; it is not the consumer's resolution source.

Run the two executable compatibility contract suites in a dedicated
`ubuntu-24.04` actions-ci job. The persistent platform-test fleet does not carry
the required bubblewrap executable, so it must not register either suite. Keep
the hosted job as a required input to the unmatrixed `shell-tests` aggregate;
missing, skipped, or failed hosted execution therefore fails the existing
required context instead of silently reducing coverage.

The hosted Ubuntu image also does not preinstall bubblewrap. Only when a
secretless PR or trusted-ref compatibility lane will execute on a GitHub-hosted
runner, acquire `bubblewrap` from the image's signed Ubuntu apt repositories.
Use no credentials and perform no broad upgrade. Require the Ubuntu package
version and executable version to meet the 0.9.0 floor used by the namespace
flags, bind `/usr/bin/bwrap` to the installed package, and require a regular,
executable, root-owned binary that is not group- or world-writable. The
actions-ci hosted contract uses the byte-identical provisioner before executing
the suites. Self-hosted runners are never installed or mutated by the workflow;
the runtime boundary continues to reject a missing or unsafe preprovisioned
binary there.

The first hosted receipt failed with the fixed `bubblewrap-unavailable`
category. Signed bubblewrap acquisition reached the next boundary, where the
unprivileged production-shaped probe failed with
`bubblewrap-namespace-denied`: Ubuntu Noble's AppArmor policy restricts
unprivileged user namespaces unless the invoking application has an explicit
profile. The hosted-only acquisition therefore also installs `apparmor` and
`apparmor-profiles`, with both packages at or above Noble's first SRU that
contains `bwrap-userns-restrict`,
`4.0.1really4.0.1-0ubuntu0.24.04.3`.

Bind `/sbin/apparmor_parser` and
`/usr/share/apparmor/extra-profiles/bwrap-userns-restrict` to those installed
packages just as bubblewrap is bound to its package. Require every file to be
regular, root-owned and root-grouped, and not group- or world-writable;
executables must be executable and the profile must not be. Before loading,
require the package profile's ABI 4.0, absolute bwrap attachment, transition
from bwrap to the restricted child profile, recursive child transition,
audited capability denial, and absence of any unconfined flag.
Reject either optional local bwrap profile override, including a broken
symlink, so the parser cannot compose unverified host policy into the signed
package profile.

The filesystem verifier additionally rejects set-id or file-capability-bearing
executables. It verifies the lexical usrmerge `/sbin` link, resolved parser and
profile ancestry, `/etc/apparmor.d[/local]`, and the complete existing ABI and
tunables include trees as root-owned, root-grouped, and not group- or
world-writable;
symlinks and special include entries fail closed. Executables, the profile, and
include files are read through no-follow descriptors and bound by metadata and
content to a deterministically ordered receipt. Both the verifier and the
privileged loader run isolated Python under a fixed empty environment, so
working-directory modules and ambient credentials cannot influence the check.
The loader recreates the expected receipt, retains the no-follow parser and
profile descriptors, and directly executes the verified parser descriptor with
the verified profile descriptor; it never returns to a pathname-based shell
load after verification.
Profile validation is block-structural: the parent transition must occur in the
bwrap block, the recursive transition and audited capability denial must occur
in the restricted child, and that exact denial is the only child rule that may
mention capabilities. This
closes the reachable non-root background-process race without claiming
protection from a pre-existing privileged process outside the workflow threat
boundary.

When this filesystem boundary fails, report only a fixed phase from a closed
allowlist: ancestor directories, the usrmerge parser link, local overrides,
the ABI or tunables tree, the bwrap or parser binary, the package profile,
profile semantics, receipt recomputation, profile load, or unknown. The
privileged loader communicates the same phases through fixed exit codes while
its stdout and stderr remain suppressed. The unprivileged verifier's shell
boundary captures all producer and interpreter output, accepts only an exact
receipt on success, and replays only an exact allowlisted diagnostic on
failure. Exception text, paths, environment values, parser output, and any
non-allowlisted value never cross the diagnostic boundary; an unexpected
failure becomes the fixed `unknown` phase.

First attempt the production namespace and capability-drop probe as the
unprivileged runner under an empty credential environment. Only if it fails,
load that verified package-owned restrictive profile with the absolute parser
under credential-scrubbed `sudo`, then require the same unprivileged probe to
pass. Never disable the AppArmor sysctl, make bubblewrap setuid, invoke
bubblewrap as root, download a profile, or fall back to weaker isolation. Those
alternatives either weaken the host policy globally or move PR-influenced path
and mount processing into a privileged process. The exact hosted actions-ci
mirror runs this same prerequisite before its compatibility contracts;
self-hosted execution remains excluded from every install and policy mutation.

When the target began absent, retain its installed directory identity and remove that
exact directory after success, script failure, `SIGINT`, or `SIGTERM`. Cleanup first
quarantines the identity under the held package parent and refuses to delete a different
entry. Existing-target swap and post-success replacement semantics remain unchanged.
No consumer self-dependency or package pin is introduced.

## Consequences

- Self-packages can exercise multiple published compatibility lanes without changing
  their dependency graph.
- Consumer code sees one fully verified staged package per lane; the initially absent
  target is absent again at job teardown.
- Consumer resolution is bound to sealed archive bytes in a read-only private
  mount, rather than inferred from equal path metadata before and after `npm`.
- Actions CI exercises that namespace boundary on an explicit hosted image and
  aggregates its result into `shell-tests`; registration mutations reject suite
  removal or reassignment to the incompatible persistent platform lane.
- Hosted package acquisition is narrowly gated, signed, credentialless, and
  fail-closed. Parity and ordering mutations prevent the contract job from
  exercising a different prerequisite than canonical node-ci consumers.
- Parent and target races fail the job and preserve unexpected state for diagnosis rather
  than deleting or overwriting it.
- Real-shaped tests cover success, script failure, signals, multiple lanes, parent and
  target symlinks, missing parents, path escape, and target appearance during
  staging. A deterministic swap/load/restore control proves pathname execution
  loads attacker bytes while the bound lane continues to load the verified
  version.
