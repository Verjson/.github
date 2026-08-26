# 0140 — Resolve package compatibility without consumer credentials

- **Date:** 2026-08-26
- **Issue:** [Verjson/.github#1103](https://github.com/Verjson/.github/issues/1103)
- **Category:** package credentials / untrusted compatibility execution — **sensitive class**
- **Status:** Accepted

## Context

The v1 readiness contract requires consumers to exercise supported retained package
ranges beside a pinned release candidate. The canonical Node workflow already separates
credentialed private-package acquisition from repository-controlled execution through
ADRs [0086](../0086-secretless-node-pr-validation/README.md),
[0095](../0095-bounded-secretless-node-cache-transfer/README.md), and
[0097](../0097-secretless-trusted-ref-node-validation/README.md). Its lock-derived
acquisition cannot fetch another published version selected only at run time.

Three consumer implementations exposed the gap. A job token scoped to one repository
could not necessarily read packages; another implementation passed a long-lived package
token into PR-authored lifecycle hooks; and source-only substitutes did not prove that a
retained published artifact remained compatible. Reimplementing acquisition in each
consumer would fork the exact-package policy, bounded transfer, provenance checks, and
credential scrub that make the canonical boundary safe.

## Decision

Add one opt-in `secretless-compatibility-ranges` input to the canonical `node-ci`
workflow. It is an exact JSON object containing one `package`, one `script`, and 1–8
unique bounded semver `ranges`. The package must already be an exact entry in
`approved-internal-packages`; the new input never expands package or scope authority.
The initial contract supports npm callers and rejects the option under another package
manager rather than approximating an offline install.

In the existing trusted acquisition job, validate the object before network access.
Resolve every range through GitHub Packages metadata reads, select the highest returned
readable version, then read that exact version's package name, version, SHA-512 integrity,
and download URL. Accept only the approved package's canonical GitHub Packages URL.
Classify authentication, authorization, missing/unreadable package, and empty-range
failures separately while scrubbing the acquisition token from bounded diagnostics.
Use the existing `npm cache add` path to acquire the exact tarball without install,
prepare, or lifecycle execution.

Record the declared request and each resolved version, integrity, URL, and digest in a
canonical provenance document. Transfer it beside only the verified content-addressed
blobs through ADR 0095's 80 MiB, exact-run, nonce-keyed cache handoff. Bind its SHA-256
into both the handoff manifest and trusted job output. The credentialless job revalidates
the outer payload, provenance digest and request, every tarball SHA-512, and the embedded
`package/package.json` name and version before reconstructing bounded local artifacts.
Tampered or surplus content fails before consumer code.

Run the declared exact `package.json` script once for each lane after installing its
verified local tarball with network fallback and lifecycle scripts disabled. Expose only
the resolved package, range, version, artifact path, and provenance path to that script.
Package, repository, cloud, and OIDC credential variables are explicitly empty, and the
runner refuses execution if any credential value survives. Thus a compatibility failure
is observed at the consumer-test layer without making PR-controlled code credentialed.

## Consequences

- Consumers can prove compatibility against versions actually readable at run time
  without committing retention-sensitive exact pins.
- A newly published version inside a declared range is tested automatically and may turn
  a previously green consumer red; this is the intended compatibility guardrail.
- The acquisition job performs bounded registry metadata reads in addition to exact
  tarball reads, but still runs no package or repository lifecycle code.
- The range input is evidence, not authority: every requested package remains subject to
  the existing exact allowlist and protected-policy rules.
- pnpm compatibility lanes require a separate reviewed offline-install design; callers
  using pnpm fail closed if they set this input.

## Rollback

Callers may omit `secretless-compatibility-ranges` without changing the existing
secretless lock validation. Reverting the workflow input and this decision removes only
runtime-resolved lanes; passing package credentials into consumer jobs is not an
acceptable rollback.
