# 0176 — Generate independent Node component release callers

- **Date:** 2026-09-12
- **Status:** Accepted for implementation
- **Issue:** [Verjson/verjson-cli#245](https://github.com/Verjson/verjson-cli/pull/245)
- **Extends:** [ADR 0069](../0069-node-publication-consumes-contract-version/README.md), [ADR 0070](../0070-component-scoped-changelog-streams/README.md)
- **Category:** release authority, package publication and credential isolation — **sensitive class**

## Context

The `release-node` generator emits one release caller. A consumer that needs to
publish a nested package as an independent stream currently has to replace the
root caller with an exact package selection, which removes root `@verjson/cli`
publication and changes the default unscoped `v` stream. Verification may also
build a nested distribution that is not present when the reusable publish job
checks out the immutable tag and packs the package with scripts disabled.

## Decision

Keep `release-node` as the canonical root caller: it defaults to prefix `v`, an
empty component, and package directory `["."]`. Add
`release-node-component`, which requires an explicit lowercase component, a
component-specific `*-v` prefix, and at least one `--only-package-dir`. It emits
an independent caller with those values as immutable defaults, a runtime binding
check, and `require-package-preparation: true`. Consumers generate one contract
test for each caller, so the root caller and component caller remain independently
validated at the same immutable generator pin.

The reusable `node-release.yml` contract accepts
`require-package-preparation`, defaulting to `false`. When true, the actual
publish job must find an executable `scripts/release-prepare-packages.sh`, run it
after checkout and private dependency installation, and propagate any failure
before package stamping, build, or script-disabled `npm pack`. When false, an
absent hook remains valid and an executable hook retains the existing behavior.
The preparation step receives no npm credential; the existing install and
publication credential scopes remain separate, and private-package refusal is
unchanged.

The publish job repeats preparation from the tagged tree rather than trusting
verification output from another job. This is the chosen artifact boundary: a
successful verification job cannot make an unbuilt nested distribution appear in
the later publish job.

## Consequences

Consumers with a nested independent package add a second generated caller and
contract test, while existing root adopters keep their generated output and
optional hook semantics. A component release fails closed when its preparation
hook is absent, non-executable, or unsuccessful. The caller still requires the
exact package selection, component, and prefix, so a dispatch cannot silently
publish the root package or another component stream.

This decision does not change registry credentials, package retention, tags,
release snapshots, or publication authorization. A later change to the hook path,
artifact handoff, or caller binding must supersede this ADR and update the
generator, reusable workflow, generated contract tests, and adopter documentation
together.
