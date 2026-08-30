# 0154 — Authenticate required-workflow identity overrides

- **Status:** Accepted
- **Date:** 2026-08-30
- **Category:** ⚠️ security-sensitive (credentialed CI admission)
- **Issue:** [Verjson/.github#1195](https://github.com/Verjson/.github/issues/1195)
- **Amended by:** [Verjson/.github#1198](https://github.com/Verjson/.github/issues/1198) — candidate environment key removal
- **Extends:** [ADR 0086](../0086-secretless-node-pr-validation/README.md)

## Context

Organization-required workflow deliveries can omit pull-request event context while the authenticated Actions run record retains the numeric pull-request binding. Adding API permissions to the existing reusable Node workflow would break callers that deliberately grant its established smaller permission set: a called workflow can only downgrade caller permissions, and an explicit job permission map sets every omitted scope to `none`.

## Decision

Keep `.github/workflows/node-ci.yml` byte-identical and generate a separate `.github/workflows/node-ci-protected.yml` from it. The protected variant requires event, head repository, and head SHA inputs and explicitly requests `actions: read` and `pull-requests: read`; adopting callers must grant those scopes. It resolves only the current `github.run_id`, verifies exactly one pull-request binding, then verifies the live numeric pull request is open with the exact head repository and SHA.

The protected variant admits only `secretless-pr=true` with `secretless-trusted-ref=false`. Embed one generated verifier byte-for-byte immediately after immutable candidate checkout, again immediately before conditional auxiliary credential use, and again before private registry/cache credential consumption. Repeat it immediately before every candidate execution route: lifecycle rebuild, exact custom script plan, the grouped default build/typecheck/test/lint plan, and runtime-resolved compatibility lanes. Guard conditions exactly match their protected operation. Every GitHub CLI boundary binds `GH_TOKEN` explicitly to `github.token`; ambient runner authentication is not authority. A synchronize, close, ambiguous binding, malformed identity, or partial API failure fails closed at the next trust boundary.

The protected execution routes remove GitHub, npm, cloud-provider, and Actions OIDC credential keys from the actual process environment before invoking candidate-controlled code. Empty values are insufficient because candidate tools can branch on key presence through `Object.hasOwn(process.env, name)`. The removal is generated into the lifecycle rebuild, exact custom plan, grouped default plan, and runtime-resolved compatibility routes while retaining the immediately preceding live-identity verifier.

The protected variant does not support `schema-dir`: that legacy route executes candidate `npm ci` with a package credential and has no secretless acquisition contract. Admission therefore rejects every non-empty `schema-dir` before candidate processing, and generation removes the schema install step entirely. Supporting schema submodules requires a separately reviewed secretless acquisition design rather than weakening this boundary.

## Consequences

- Existing callers retain the exact previous workflow bytes, permissions, behavior, and checkout semantics.
- Protected identity inputs add no authority: they are claims checked against the current authenticated run and live pull request.
- Required-workflow adopters explicitly grant `actions: read` and `pull-requests: read` and call the protected variant.
- The cli-projects required workflow remains unchanged until a second change pins and consumes the merged prerequisite revision.
