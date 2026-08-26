# 0141 — Swap verified compatibility packages without graph resolution

- **Date:** 2026-08-26
- **Issue:** [Verjson/.github#1105](https://github.com/Verjson/.github/issues/1105)
- **Category:** package credentials / untrusted compatibility execution — **sensitive class**
- **Status:** Accepted
- **Extends:** [ADR 0140](../0140-resolve-package-compatibility-without-consumer-credentials/README.md)

## Context

ADR 0140 acquires, binds, and transfers exact compatibility package artifacts
without exposing a package credential to pull-request code. Its credentialless
lane then used `npm install` to place each verified artifact into the consumer.
Even offline and without lifecycle scripts, that command re-resolved the
consumer dependency graph instead of preserving the graph already installed
from the verified lockfile cache.

Authn and OIDC consumers exposed this gap: their ordinary public caret
dependencies were installed at exact locked versions, and their tarballs were
present in the cold cache, but npm still requested absent registry packuments.
The compatibility lane therefore failed before exercising the candidate even
though every byte needed by the locked consumer graph was available.

Replacing npm graph resolution with archive extraction crosses the untrusted
package execution boundary. The replacement must reject archive confusion and
must not introduce a check/use gap between the bytes that passed provenance
verification and the bytes installed for consumer execution.

## Decision

Read each transferred compatibility artifact once through a no-follow file
descriptor, require it to be a regular file no larger than 32 MiB, and verify
its SHA-512 digest against trusted acquisition provenance. All subsequent
archive validation and extraction use only that immutable in-memory snapshot.

Accept at most 4,096 members and 64 MiB of declared expanded regular-file
content under one exact `package/` root. Reject absolute paths, backslashes,
empty or dot segments, traversal, duplicate members, additional roots,
symlinks, hardlinks, devices, FIFOs, and every other non-directory,
non-regular type. Create the staged tree through no-follow directory file
descriptors with exclusive file creation rather than a general-purpose tar
extractor. Parse the staged `package.json` and require the exact provenance
name and version before installation.

Preserve the consumer graph installed by the canonical secretless lock
validation. Atomically rename the previously installed package into a private
same-parent backup, rename the staged verified package into its exact
`node_modules` location, then reopen and re-check the installed manifest's
exact name and version. Restore the original package on any failed swap or
post-swap check, and remove private staging and backup directories on both
success and failure. A missing, symlinked, or non-directory installed target
fails closed; compatibility mode does not install a new dependency or expand
package scope.

Do not invoke a package manager, registry, package lifecycle, or package script
during the swap. Run only the caller-declared consumer compatibility script
after every lane passes provenance, archive, manifest, and swap validation and
after package, repository, cloud, and OIDC credentials have been scrubbed.

The artifact file-descriptor snapshot closes the relevant artifact
time-of-check/time-of-use gap. Directory-descriptor extraction and a
same-filesystem rename make the staged transition atomic. Pull-request code
can still mutate files in its own same-UID workspace once consumer execution
begins; it receives no credential or elevated authority, so that ordinary
workspace ownership remains outside this credential boundary.

## Consequences

- Compatibility lanes exercise candidates against the exact consumer graph
  already proven by secretless lockfile validation, including a cold cache
  without public registry packuments.
- Archive acceptance is deliberately narrower than npm tarball acceptance;
  packages requiring links, special entries, multiple roots, or the declared
  bounds fail before consumer code.
- Compatibility packages must already exist as real installed directories.
  The lane proves replacement compatibility and cannot manufacture an
  undeclared dependency.
- Candidate lifecycle scripts never run. Consumers test the candidate only
  through their explicitly declared compatibility script.

## Rollback

Callers can omit `secretless-compatibility-ranges`. Reintroducing package-manager
graph resolution in the credentialless lane is not an acceptable rollback;
any replacement must retain immutable provenance-bound bytes, bounded archive
validation, graph preservation, credential scrubbing, and fail-closed swap
semantics.
