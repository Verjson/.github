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
`NODE_AUTH_TOKEN`. Every caller also grants `packages: read` because the reusable
acquisition job requests it, although the build job itself requests no package
permission.

For validation of repositories with approved private dependencies, the
`secretless-pr` and `secretless-trusted-ref` modes split acquisition from
repository-controlled execution. The
acquisition job requests only `contents: read` and `packages: read` plus the
explicitly mapped package token, validates every package under the exact approved
scopes against the newline-separated package allowlist and GitHub Packages URL,
rejects repository
`.npmrc` files, and populates a cache with only the exact private download URLs
under a job-created config that scopes the token to `npm.pkg.github.com`.
When the lock contains no internal package and the allowlist is empty,
acquisition creates an empty content set without making a tokened npm request.

Secretless callers may set `package-manager: pnpm`. The caller must commit
`pnpm-lock.yaml` lockfile version 9 and an integrity-pinned Corepack
`packageManager` value such as `pnpm@11.20.0+sha512.<digest>` in `package.json`.
The same exact package/scope/URL/SHA-512 policy applies. Acquisition downloads
only those reviewed private tarballs and runs no pnpm command. After credential
scrub, the build imports the verified blobs into a run-attempt-local pnpm store
and runs `pnpm install --frozen-lockfile --ignore-scripts --prefer-offline`.
The default remains `npm`, so existing callers and their package-lock behavior
do not change.

A pnpm-only caller adds the same input to both secretless jobs and can retain its
ordered browser-test plan:

```yaml
with:
  package-manager: pnpm
  secretless-pr: true
  approved-internal-packages: |
    @verjson/identity-contracts
  secretless-ci-script-plan: >-
    ["typecheck", "build", "test:visual"]
```

Use `secretless-trusted-ref: true` instead of `secretless-pr` in the trusted-ref
job; all other package policy and script-plan inputs must remain identical.
No install or lifecycle script runs in acquisition. The default approved scope is
`@verjson`; callers that need another internal scope must name it exactly and set
the protected repository variable `VERJSON_SECRETLESS_PACKAGE_POLICY` to a JSON
object containing the exact `scopes` and `packages` arrays. An optional auxiliary
source resolves one repository-controlled pin to a full commit SHA, performs one
sparse private checkout, and adds only the exact sparse content path to the
transfer. Its four input fields must exactly match protected repository variable
`VERJSON_SECRETLESS_AUXILIARY_POLICY`, so a PR cannot redirect the acquisition
token to another repository or path. It transfers npm's verified content-addressed download
cache, never `node_modules`, under an 80 MiB payload cap. Acquisition saves the
two-file envelope under an exact run-attempt Actions cache key with no restore
prefix. The build job requires that exact cache hit and verifies the exact run,
attempt, package-lock digest, auxiliary repository/commit/path identity, payload
digest, and size before running
`npm ci --prefer-offline --ignore-scripts` with package, Git, cloud, and OIDC credential
paths empty. Job-local `always()` cleanup removes acquisition and restored state
on success, failure, and cancellation. No Actions artifact is created. Secretless
mode ignores the caller's `cache: true`; its handoff cache has one exact-attempt
key and no cross-run restore, and consumer npm commands use a job-scoped runtime
cache that is removed at teardown:

```yaml
jobs:
  ci:
    permissions:
      contents: read
      packages: read
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

Do not use `secrets: inherit` on this route. Every caller grants `packages: read`
because reusable-workflow job permissions cannot elevate the caller permission
ceiling, even when `NODE_AUTH_TOKEN` is a dedicated token. That capability exists
only in acquisition. The build job retains only `contents: read` and scrubs
GitHub token paths before repository commands. All
PR acquisition and build jobs ignore the caller runner override and use the
isolated untrusted lane or a fresh hosted fallback. `secretless-pr` rejects
non-PR events and fork PRs. Both modes reject schema submodules, repository npm
config, unlisted internal packages, non-GitHub package URLs, old lockfile
formats, and unused
allowlist entries. Forks fail closed because pull-request secrets are unavailable;
do not replace `pull_request` with `pull_request_target` to obtain them. Existing callers keep
the original single-job install path because the mode defaults off.

Trusted post-merge or direct-ref validation uses a separate caller job with
`secretless-trusted-ref: true`. The credentialed acquisition job still runs on
the isolated lane and still executes no repository lifecycle or consumer script.
The credentialless build job follows the normal trusted-ref runner route (or an
explicit caller runner), after checkout credentials and package, Git, cloud, and
OIDC paths are scrubbed. Admission accepts only `push` and an explicit
`workflow_dispatch`; `pull_request`, `pull_request_target`, schedules, and every
other event fail before token use. The two booleans are mutually exclusive.
A trusted push bypasses a stale `renovate/stability-days` status. Existing
eligibility behavior stays intact for other events, while explicit dispatch
retains its established manual override.

Keep event admission and permissions visible in the caller. Do not use
`secrets: inherit`; map only `NODE_AUTH_TOKEN` into each reusable invocation:

```yaml
on:
  pull_request:
  push:
    branches: [main]
  workflow_dispatch:

jobs:
  pull-request:
    if: github.event_name == 'pull_request'
    permissions:
      contents: read
      packages: read
      statuses: read
    uses: Verjson/.github/.github/workflows/node-ci.yml@<40-hex-canonical-contract-sha>
    with:
      secretless-pr: true
      approved-internal-packages: '@verjson/identity-contracts'
    secrets:
      NODE_AUTH_TOKEN: ${{ secrets.NODE_AUTH_TOKEN }}

  trusted-ref:
    if: github.event_name == 'push' || github.event_name == 'workflow_dispatch'
    permissions:
      contents: read
      packages: read
      statuses: read
    uses: Verjson/.github/.github/workflows/node-ci.yml@<40-hex-canonical-contract-sha>
    with:
      secretless-trusted-ref: true
      approved-internal-packages: '@verjson/identity-contracts'
    secrets:
      NODE_AUTH_TOKEN: ${{ secrets.NODE_AUTH_TOKEN }}
```

Both jobs grant `packages: read` because both invoke the reusable acquisition
job. The mapped package token does not change that caller contract.

For parity with PR validation, pass the same exact
`approved-internal-scopes`, `approved-internal-packages`,
`secretless-auxiliary-source`, `secretless-rebuild-packages`, and
`secretless-ci-script-plan` values to both jobs. That keeps the private cache,
immutable auxiliary tree, rebuild allowlist, and ordered audit/smoke plan
identical across the event split.

Consumers that need a reviewed private auxiliary tree, selective lifecycle
rebuilds, or a repository-specific command sequence keep those choices explicit.
The auxiliary source accepts exactly `repository`, `pinFile`, `checkoutPath`, and
`sparsePath`; the pin file must name the same repository and a lowercase 40-hex
commit. Rebuild entries must be exact locked package names. The script plan must
be a unique JSON array of exact `package.json` script names or exact
`{"script":"name","unsetEnv":["NAME"]}` objects. `unsetEnv` may remove up to 16
non-credential environment names for that single script; package, Git, cloud, and
OIDC credential controls cannot be removed. Both features execute only after
credential scrub and the offline install. When a script plan is supplied it
replaces the default build/typecheck/test/lint sequence.

The handoff uses the repository cache service rather than organization artifact
storage. Acquisition generates an unguessable nonce and binds it with
`github.run_id` and `github.run_attempt`; restore uses the internally passed key
with no prefix and fails on a missing exact match. Save and restore use the same
stable relative workspace path, so cache version identity does not depend on a
runner's work root. Use **Re-run all jobs** for a new
attempt. Re-running only a failed build job cannot create its missing acquisition
cache and fails closed by design.

To adopt the #750 contract, pin the reusable path to the 40-hex commit that
contains this change—never a branch or moving tag:

```yaml
uses: Verjson/.github/.github/workflows/node-ci.yml@<40-hex-canonical-contract-sha>
```

Preserve the exact internal-package allowlist and update that pin atomically. No
caller permission change is required. This Node caller is not generated by the changelog tooling.
If the same adoption also advances canonical changelog artifacts, run
`Verjson/.github/scripts/gen-changelog-caller.sh` at that same immutable SHA and
regenerate its `workflow`, `renderer`, `contract-test`, and release caller
together; never handwrite or partially repin those generated artifacts.

For `tequityapp/tequity-api`, the canonical caller that replaces its handwritten
acquisition/build split is:

```text
VERJSON_SECRETLESS_PACKAGE_POLICY={"scopes":["@tequityapp","@verjson"],"packages":["@tequityapp/tequity-schema","@verjson/ai","@verjson/authn","@verjson/authz","@verjson/cloud-storage","@verjson/customer-lifecycle","@verjson/graphql-conventions","@verjson/identity-contracts","@verjson/object-storage","@verjson/observability","@verjson/oidc-claims-middleware","@verjson/payments","@verjson/pg"]}
VERJSON_SECRETLESS_AUXILIARY_POLICY={"repository":"tequityapp/tequity-worker","pinFile":"config/worker-schema-pin.json","checkoutPath":".worker-schema","sparsePath":"migrations"}
```

Set both values as repository variables outside the PR branch, then use:

```yaml
jobs:
  ci:
    permissions:
      contents: read
      packages: read
      statuses: read
    uses: Verjson/.github/.github/workflows/node-ci.yml@<40-hex-canonical-contract-sha>
    with:
      secretless-pr: true
      approved-internal-scopes: |
        @tequityapp
        @verjson
      approved-internal-packages: |
        @tequityapp/tequity-schema
        @verjson/ai
        @verjson/authn
        @verjson/authz
        @verjson/cloud-storage
        @verjson/customer-lifecycle
        @verjson/graphql-conventions
        @verjson/identity-contracts
        @verjson/object-storage
        @verjson/observability
        @verjson/oidc-claims-middleware
        @verjson/payments
        @verjson/pg
      secretless-auxiliary-source: >-
        {"repository":"tequityapp/tequity-worker","pinFile":"config/worker-schema-pin.json","checkoutPath":".worker-schema","sparsePath":"migrations"}
      secretless-rebuild-packages: |
        argon2
        esbuild
      secretless-ci-script-plan: >-
        ["verify:worker-schema","build","audit:deps","lint","test","typecheck:smoke",{"script":"smoke:otel","unsetEnv":["OTEL_SDK_DISABLED"]}]
      db-image: pgvector/pgvector:pg16
      db-env: |
        POSTGRES_PASSWORD=postgres
        POSTGRES_DB=tequity
        DATABASE_URL=postgres://postgres:postgres@127.0.0.1:${DB_PORT}/tequity
        TEQUITY_DISPOSABLE_TEST_CLUSTER=true
        OPENAI_API_KEY=ci-dummy-key
        OTEL_SDK_DISABLED=true
        TEQUITY_WORKER_MIGRATIONS_DIR=${{ github.workspace }}/.worker-schema/migrations
      cache-image: redis:7-alpine
      cache-env: |
        TEST_REDIS_URL=redis://127.0.0.1:${CACHE_PORT}
    secrets:
      NODE_AUTH_TOKEN: ${{ secrets.NODE_AUTH_TOKEN }}
```

Keep the pin file and every allowlist entry repository-reviewed. The caller uses
the reusable workflow directly; do not copy its acquisition or validation steps
into the consumer. If changelog contract artifacts move in the same adoption,
generate all four with `Verjson/.github/scripts/gen-changelog-caller.sh` at the
same immutable contract SHA.

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

`node-release.yml` is publish-only. It requires an existing SemVer tag in the
declared `v` or stream namespace, checks out that exact tag, verifies its
immutable `CHANGELOG/<version>.md`, then publishes the package and GitHub release.
The full namespace is stripped before package stamping, so `python-v1.2.3`
publishes package version `1.2.3`. It cannot create a tag, push a commit, inspect
commit subjects, or choose a version.

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
      prefix: ${{ inputs.prefix }}
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
