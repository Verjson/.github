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
- Parent and target races fail the job and preserve unexpected state for diagnosis rather
  than deleting or overwriting it.
- Real-shaped tests cover success, script failure, signals, multiple lanes, parent and
  target symlinks, missing parents, path escape, and target appearance during
  staging. A deterministic swap/load/restore control proves pathname execution
  loads attacker bytes while the bound lane continues to load the verified
  version.
