# Protected consumer-owned type-surface baselines

The organization-owned reusable workflow is
`.github/workflows/type-surface-ci.yml`. It resolves a pull request's base SHA
once through the authenticated GitHub API, reads the declaration from that
immutable base, validates it against `CI_SECRETLESS_PACKAGE_POLICY`, resolves
the exact GitHub Packages artifact, and runs the declared script through the
credentialless `node-ci` lane. The evidence receipt is generated and verified
by the same canonical workflow.

To adopt it in an `@verjson/*` package repository:

1. Add `.github/ci/type-surface-baseline.json` on the protected default branch.
   It must contain exactly `package`, `version`, and `script`; `version` is an
   exact released `x.y.z`, never `latest` or a Git SHA.
2. Add the approved package and the repository's compatibility script to the
   protected `CI_SECRETLESS_PACKAGE_POLICY` variable. The exact version must
   be inside the package's authorized compatibility ranges.
3. Make the script consume
   `VERJSON_SECRETLESS_COMPATIBILITY_ARTIFACT_DIR` and
   `VERJSON_SECRETLESS_COMPATIBILITY_PROVENANCE`; it must not fetch packages or
   use credentials itself.
4. In `Verjson/.github`, generate the repository-owned required-workflow caller
   with:

   ```bash
   scripts/gen-type-surface-caller.sh \
     <canonical-contract-sha> \
     Verjson/example \
     .github/ci/type-surface-baseline.json \
     <package> <script> \
     $'@verjson/package\n@verjson/tsconfig' \
     > .github/workflows/example-type-surface-required.yml
   ```

The generated required workflow lives in `Verjson/.github`; the package
repository receives no workflow copy that a pull request could replace. Its
expected package/script and immutable canonical SHA are part of the adoption
contract. Do not hand-write a lookalike workflow or put a baseline version in
the caller.
