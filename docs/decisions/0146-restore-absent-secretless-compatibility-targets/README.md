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
- Parent and target races fail the job and preserve unexpected state for diagnosis rather
  than deleting or overwriting it.
- Real-shaped tests cover success, script failure, signals, multiple lanes, parent and
  target symlinks, missing parents, path escape, and target appearance during staging.
