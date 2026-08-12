# Reusable Node workflow controls

`node-ci.yml` and `node-release.yml` bound each job to 30 minutes after a runner
starts it. Queue time is not part of that bound. Callers with a legitimately
longer suite can set the numeric `timeout-minutes` input:

```yaml
jobs:
  ci:
    uses: Verjson/.github/.github/workflows/node-ci.yml@v2.2.0
    with:
      timeout-minutes: 45
```

Both workflows default GitHub Actions cache transfer **off** on the persistent
self-hosted pool. The runner's local npm download cache remains available, while
the accumulated cross-repository cache is never restored from or uploaded to
Actions. This avoids the failure observed in `Verjson/toquorum` run
`30363686973`, where a 4.1 GB cache kept each runner occupied for another 17–27
minutes after useful work completed. Omitting the input is equivalent to
`cache: false`.

Enable `cache: true` only for an isolated/cold runner that benefits from remote
restore. Enabled caches use a job-scoped directory under `runner.temp`, never
the persistent global npm cache, and default to a 1024 MB upload limit. Caches
over `cache-max-mb` are reported and cleared before setup-node's post step:

```yaml
jobs:
  ci:
    uses: Verjson/.github/.github/workflows/node-ci.yml@v2.2.0
    with:
      cache: true
      cache-max-mb: 512
      cache-dependency-path: packages/service/package-lock.json
```

`cache-dependency-path` may also be a glob understood by `hashFiles` and
`actions/setup-node`. If it matches no lockfile, caching is skipped and the job
continues normally. Registry authentication is independent of the job token and
caching: callers that install private `@verjson` packages pass
`NODE_AUTH_TOKEN`. The reusable build job requests no package permission, so a
caller's legacy `packages: read` grant is harmless but unnecessary.

For pull-request validation of repositories with approved private dependencies,
`secretless-pr` splits installation from repository-controlled execution. The
acquisition job receives only `contents: read` plus the explicitly mapped package
token, validates every `@verjson` package against the exact newline-separated
allowlist and GitHub Packages URL, rejects repository `.npmrc` files, and runs
`npm ci --ignore-scripts` with a job-created config that scopes the token only to
`npm.pkg.github.com`. It transfers only npm's verified content-addressed download
cache, never `node_modules`, under an 80 MiB payload cap (the complete two-file
artifact envelope is budgeted below 81 MiB). A separate job verifies the exact run,
attempt, package-lock digest, payload digest, and size before running
`npm ci --offline --ignore-scripts` with package, Git, cloud, and OIDC credential
paths empty. The local transfer is removed immediately after installation and a
no-checkout cleanup job deletes the exact artifact after build, test, and lint
finish or fail. Secretless mode ignores `cache: true`; it neither restores nor
uploads the cross-run Actions npm cache, and consumer npm commands use a
job-scoped runtime cache that is removed at teardown:

```yaml
jobs:
  ci:
    permissions:
      actions: write
      contents: read
      statuses: read
    uses: Verjson/.github/.github/workflows/node-ci.yml@<immutable-sha>
    with:
      secretless-pr: true
      approved-internal-packages: |
        @verjson/identity-contracts
        @verjson/tsconfig
    secrets:
      NODE_AUTH_TOKEN: ${{ secrets.NODE_AUTH_TOKEN }}
```

Do not use `secrets: inherit` on this route. The caller deliberately omits
`packages: read`; the package token belongs only to the acquisition job and PR
code cannot request the job token's package capability. `actions: write` is
available only to the no-checkout deletion job; the build job retains
`contents: read` and scrubs GitHub token paths before repository commands. All
three jobs ignore the caller runner override and use the isolated untrusted lane
or a fresh hosted fallback. Secretless mode rejects
non-PR events, fork PRs, schema submodules, repository npm config, unlisted
internal packages, non-GitHub package URLs, old lockfile formats, and unused
allowlist entries. Forks fail closed because pull-request secrets are unavailable;
do not replace `pull_request` with `pull_request_target` to obtain them. Existing callers keep
the original single-job install path because the mode defaults off.

Artifact deletion is bounded to five minutes and runs under `always()` after
success, failure, or cancellation. One-day retention remains a platform fallback
when GitHub cannot schedule cleanup; deletion and expiry do not imply immediate
quota reclamation because GitHub storage accounting can lag by 6–12 hours.
Use **Re-run all jobs** for a new attempt. Re-running only a failed build job
cannot reuse the deleted prior-attempt artifact and fails closed by design.

To adopt the #750 contract, pin the reusable path to the 40-hex commit that
contains this change—never a branch or moving tag:

```yaml
uses: Verjson/.github/.github/workflows/node-ci.yml@<40-hex-canonical-contract-sha>
```

Add `actions: write`, preserve the exact internal-package allowlist, and update
that pin atomically. This Node caller is not generated by the changelog tooling.
If the same adoption also advances canonical changelog artifacts, run
`Verjson/.github/scripts/gen-changelog-caller.sh` at that same immutable SHA and
regenerate its `workflow`, `renderer`, `contract-test`, and release caller
together; never handwrite or partially repin those generated artifacts.

The `setup-verjson-node` composite also defaults caching off and scopes an
explicitly enabled cache to the current job. Because a setup composite finishes
before caller-owned install/build steps, bespoke callers—not the composite—own
any end-of-job size guard.

`node-ci.yml` also exports `VERJSON_CHANGELOG_TOOL_CACHE` beneath
`runner.temp`. This keeps a cold changelog-contract cache writable by the job
user without trusting persistent runner state; generated changelog tooling
still verifies every cached file against its pinned digest.

## Runner security tiers

| Tier | Workload | Route | Cache and credential posture |
|---|---|---|---|
| Isolated | Public repositories, fork PRs, or sensitive untrusted validation | Fixed GitHub-hosted image until the one-job ephemeral lane in `Verjson/verjson-github-runner#33` is proven | Fresh filesystem; no inherited secrets, cloud metadata, internal network, or host Docker socket |
| Trusted | Same-repository PRs and releases in selected private repositories | `["self-hosted","GCP"]` in a selected-repository runner group | Actions cache off; explicit least-privilege job permissions; no release secrets in PR jobs |
| Fast | Low-risk trusted validation that can share setup | Trusted route with one consolidated job | Install/generate once; local npm cache only; stale-run cancellation |

Runner labels describe capability, but runner-group access is the authorization
boundary. Public repositories must not receive the persistent GCP group merely
because a workflow names its labels. Third-party actions and reusable workflows
remain full-SHA or immutable-release pinned.

## Concurrency belongs to the caller

The reusable workflows intentionally do not set `concurrency`. Pull-request CI
usually should cancel a stale run when a newer commit arrives:

```yaml
concurrency:
  group: ci-${{ github.event.pull_request.number || github.ref }}
  cancel-in-progress: true
```

Release cancellation is different: interrupting a run after publication starts
can leave a partially completed release. Release callers should normally use a
stable branch/ref group with `cancel-in-progress: false`, or omit concurrency
when overlapping release triggers are already impossible. Choose at the caller,
where the event and publication semantics are known.

## Publishing a contract-selected release

`node-release.yml` is publish-only. It requires an existing v-prefixed SemVer
tag, checks out that exact tag, verifies its immutable `CHANGELOG/<version>.md`,
then publishes the package and GitHub release. It cannot create a tag, push a
commit, inspect commit subjects, or choose a version.

Use the generated dispatched caller; it verifies the source tree, calls
`changelog-release.yml` to create the snapshot and tag, then calls
`node-release.yml` with the same explicit version:

```yaml
jobs:
  publish:
    needs: snapshot
    uses: Verjson/.github/.github/workflows/node-release.yml@<immutable-sha>
    with:
      version: ${{ inputs.version }}
      node-version: '24'
      scope: '@verjson'
      package-dirs: '["."]'
    secrets:
      NODE_AUTH_TOKEN: ${{ secrets.NODE_AUTH_TOKEN }}
  announce:
    needs: publish
    if: needs.publish.outputs.new-release-published == 'true'
    runs-on: ubuntu-24.04
    steps:
      - run: echo "published ${{ needs.publish.outputs.new-release-version }}"
```

The generated caller pins both reusable workflows to one immutable contract SHA
and passes the same Node version, required GitHub Packages scope, package
directory set, and runner policy to verification and publication. An empty
publication scope is rejected at the reusable boundary; this workflow does not
claim public-npm support while its credentials and restart proof target GitHub
Packages. Regenerate the caller and its contract test together when any of
those parameters change; never use `@main`.

Two properties to respect:

- **Compare against `'true'`, never against `'false'`.** Workflow outputs are
  strings, and a job that failed or was skipped propagates an *empty* value.
  `== 'true'` therefore treats "did not publish", "failed", and "never ran" alike
  and declines to fire; `!= 'false'` fires on all three.
- **`new-release-published` is emitted last.** It is `'true'` only after both
  `npm publish` and `gh release create --verify-tag` succeed.
- **Installation and publication use different credentials.** Pass
  `NODE_AUTH_TOKEN` for private cross-repository dependencies. The reusable
  workflow uses its repository-scoped `GITHUB_TOKEN` only to publish that
  repository's package and GitHub release.
