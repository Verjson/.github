# Protected consumer-owned type-surface baseline adoption

Use this contract when an `@verjson/*` package needs a published type-surface
compatibility baseline.

1. Add `.github/ci/type-surface-baseline.json` on protected `main` with exactly
   these fields and no others:

   ```json
   {
     "package": "@verjson/<package>",
     "version": "<released-semver>",
     "script": "<package-json-compatibility-script>"
   }
   ```

   The version is an exact released semantic version. Do not use `latest`, a
   Git SHA, a floating branch, or a prerelease unless the protected caller
   explicitly enables prerelease authorization.

2. Add that exact package/version to the repository's protected
   `CI_SECRETLESS_PACKAGE_POLICY` compatibility map. The declaration is a
   subset of policy; it never expands policy.

3. Generate the required caller from the protected workflow shape in
   `scripts/gen-authn-type-surface-required-workflow.py`, pinning
   `Verjson/.github/.github/workflows/node-ci-protected.yml` to one immutable
   contract SHA. Pass the pull-request event/head inputs, declaration path,
   expected package and script, approved internal packages, and the exact
   credentialless `build` plan. Do not pass a consumer-managed SHA or
   auxiliary baseline path.

4. Make the package's compatibility script consume
   `VERJSON_COMPATIBILITY_ARTIFACT`, `VERJSON_COMPATIBILITY_VERSION`, and
   `VERJSON_TYPE_SURFACE_BASE_SHA`. The protected workflow supplies the
   authenticated artifact and exact base SHA; the package must not resolve a
   floating baseline itself.

5. Run the generated contract tests, the protected baseline adversarial tests,
   and the package's normal release/changelog checks. Land the declaration
   before relying on it for a pull request.

The reusable workflow owns authenticated GitHub Contents lookup at the exact
pull-request base SHA, credential isolation, policy enforcement, registry
integrity/provenance, receipt binding, and fail-closed verification. The
package repository owns only the three-field declaration.
