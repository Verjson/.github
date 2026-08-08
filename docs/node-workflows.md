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
continues normally. Registry authentication is independent of caching:
callers that install private `@verjson` packages must still grant
`packages: read` and pass `NODE_AUTH_TOKEN`.

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
