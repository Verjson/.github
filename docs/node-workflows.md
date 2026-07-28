# Reusable Node workflow controls

`node-ci.yml` and `node-release.yml` bound each job to 30 minutes after a runner
starts it. Queue time is not part of that bound. Callers with a legitimately
longer suite can set the numeric `timeout-minutes` input:

```yaml
jobs:
  ci:
    uses: Verjson/.github/.github/workflows/node-ci.yml@v2.1.1
    with:
      timeout-minutes: 45
```

Both workflows cache npm's download cache by default when `package-lock.json`
exists. They never cache `node_modules`, a workspace, or build output. Set
`cache: false` to disable caching, or point `cache-dependency-path` at the
lockfile that should key the cache:

```yaml
jobs:
  ci:
    uses: Verjson/.github/.github/workflows/node-ci.yml@v2.1.1
    with:
      cache-dependency-path: packages/service/package-lock.json
```

`cache-dependency-path` may also be a glob understood by `hashFiles` and
`actions/setup-node`. If it matches no lockfile, caching is skipped and the job
continues normally. Registry authentication is independent of caching:
callers that install private `@verjson` packages must still grant
`packages: read` and pass `NODE_AUTH_TOKEN`.

The same `cache` and `cache-dependency-path` contract is available on the
`setup-verjson-node` composite action.

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
