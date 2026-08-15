# Immutable container candidate adoption

Adoption publishes an attested candidate from `main`; it does not create a stable
release or deploy anything. First commit a reviewed `container-candidate.json` with
the repository, its exact `ghcr.io/<owner>` namespace, `nextStableVersion`, and the
complete image/variant/platform matrix. A derived image names `baseVariant`; the
candidate manifest then binds it to the base index digest produced by that same run.

At one immutable `Verjson/.github` commit, acquire
`scripts/gen-container-candidate.sh`, then generate and commit all three outputs:

```sh
scripts/gen-container-candidate.sh workflow <contract-sha> container-candidate.json > .github/workflows/container-candidate.yml
scripts/gen-container-candidate.sh validator <contract-sha> container-candidate.json > scripts/container_release_manifest.py
scripts/gen-container-candidate.sh contract-test <contract-sha> container-candidate.json > scripts/container-candidate-contract.test.sh
chmod +x scripts/container_release_manifest.py scripts/container-candidate-contract.test.sh
```

The workflow, validator, and generated contract test must share that exact pin.
Run the generated test in CI. Pull requests execute only the credential-free build
path. Default-branch pushes publish commit-addressed and
`<nextStableVersion>-rc.<run_id>.<run_attempt>` identities, then retain the complete
candidate manifest. Downstream automation consumes its digests, never its tags.

Consumers whose lockfile resolves private `@verjson/*` packages list every exact
package name in `privateNodePackages`. The canonical acquisition job validates the
allowlist against `package-lock.json`, accepts only canonical registry URLs with exact
SHA-512 integrity, and runs `npm ci --ignore-scripts` with isolated npm configuration.
The resulting `node_modules` tree is bound to the workflow run, attempt, and lockfile
digest. The trusted job saves it under an unguessable exact-attempt repository cache
key; build jobs use no restore prefix and fail on a miss. BuildKit receives only that
credential-free tree as the named context `verjson_node_modules`; it never receives the
acquisition token or npm configuration.
Such a consumer uses the context explicitly, for example:

```Dockerfile
COPY --from=verjson_node_modules /node_modules ./node_modules
```

Private-package adoption requires two reviewed pull requests. First merge the
`container-candidate.json` and lockfile containing the complete
`privateNodePackages` allowlist **without enabling the generated candidate caller**.
Then generate and enable the candidate caller in a second pull request. The second
pull request may use package credentials because its requested allowlist exactly
matches the already reviewed base-branch configuration. A single pull request that
both introduces `privateNodePackages` and enables the caller intentionally fails
closed; PR-head configuration cannot authorize its own credential use.

An absent `privateNodePackages` field preserves the existing build path. A fork PR
that requests private packages fails before credential use, as does an unapproved
package, a non-registry URL, a stale integrity, or a PR-controlled `.npmrc`.
If dependency lifecycle scripts are required, run them later inside credential-free
Docker execution after copying the context; credentialed acquisition never executes them.

This contract is separate from the repository changelog contract. Continue to use
`Verjson/.github/scripts/gen-changelog-caller.sh` for the changelog workflow,
renderer, and contract test at their one immutable contract SHA; do not replace or
hand-edit those generated artifacts.
