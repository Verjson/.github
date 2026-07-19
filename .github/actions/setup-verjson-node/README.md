# `setup-verjson-node`

Composite action that does the verJSON Node-on-self-hosted setup once, so no
repo has to hand-roll it. It:

1. installs Node via `actions/setup-node` (self-hosted runners have **no ambient
   Node** — relying on it is `verjson-cli-cloud#59` Gap 2);
2. authenticates the `@verjson` GitHub Packages registry;
3. idempotently rewrites `ssh://`/`git@`→`https://` git URLs so private
   `@verjson` git dependencies resolve over HTTPS, using `--unset-all`/`--add`
   so it survives the **persistent runner's shared `~/.gitconfig`** (a plain set
   collides — `verjson-cli-cloud#59` Gap 1);
4. wires the registry token (`NODE_AUTH_TOKEN`) and an optional git token for
   private git deps **without writing the secret to the shared gitconfig** — the
   credential helper reads the token from the job environment at clone time.

## When to use it

- **Bespoke per-repo CI** (a `ci.yml` with its own jobs — e.g. `viager-app`,
  `verjson-cli-cloud`): drop this action in wherever you were copy-pasting the
  setup-node + `git config insteadOf` dance.
- **Plain Node libraries** don't need it directly — use the
  [`node-ci`](../../workflows/node-ci.yml) / [`node-release`](../../workflows/node-release.yml)
  reusable workflows, which cover the common `npm ci / build / test / lint` case.

## Usage

```yaml
jobs:
  build:
    runs-on: [self-hosted, GCP] # or [self-hosted, docker] for Docker/kind jobs
    permissions:
      contents: read
      packages: read
    steps:
      - uses: actions/checkout@v7
      - uses: Verjson/.github/.github/actions/setup-verjson-node@main
        with:
          node-version: '24' # optional; defaults to 24
          # scope: '@verjson'          # optional; set '' to skip registry auth
          node-auth-token: ${{ secrets.NODE_AUTH_TOKEN }} # read:packages
          git-token: ${{ secrets.OIDC_REPO_TOKEN }} # optional; private git deps
      - run: npm ci # NODE_AUTH_TOKEN is already exported
      - run: npm run build
```

Reference it by `@main` for now; when the reusable-workflow tag pin lands
(issue #31 item 5) this action gets pinned alongside.

## Inputs

| Input             | Default                        | Notes                                                             |
| ----------------- | ------------------------------ | ----------------------------------------------------------------- |
| `node-version`    | `24`                           | Passed to `actions/setup-node`.                                   |
| `scope`           | `@verjson`                     | npm scope for the registry; empty string skips registry auth.     |
| `registry-url`    | `https://npm.pkg.github.com`   | Registry for the scope.                                           |
| `node-auth-token` | `''`                           | `read:packages` token; re-exported as `NODE_AUTH_TOKEN`.          |
| `git-token`       | `''`                           | `repo`-scoped token for private git deps; empty leaves git as-is. |

## Tests

The idempotency and secret-hygiene logic lives in `configure-git.sh` and is
covered by `configure-git.test.sh` (plain bash, no test-framework dependency),
run in CI by [`actions-ci.yml`](../../workflows/actions-ci.yml):

```bash
bash .github/actions/setup-verjson-node/configure-git.test.sh
```
