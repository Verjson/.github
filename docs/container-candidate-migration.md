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

This contract is separate from the repository changelog contract. Continue to use
`Verjson/.github/scripts/gen-changelog-caller.sh` for the changelog workflow,
renderer, and contract test at their one immutable contract SHA; do not replace or
hand-edit those generated artifacts.
