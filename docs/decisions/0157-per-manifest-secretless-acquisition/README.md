# 0157 — Scope secretless acquisition and authorization per declared manifest

- **Date:** 2026-09-01
- **Status:** Accepted
- **Issue:** [#1229](https://github.com/Verjson/.github/issues/1229)

## Context

`node-ci.yml`'s secretless mode exists to keep a package-read credential out of
any job that executes PR-authored code. A credentialed
`acquire-secretless-dependencies` job validates every private `@verjson/*`
download against an explicit `approved-internal-packages` allowlist, packages the
verified blobs into a bounded npm cache, and hands them to a credentialless
`build-test` job through a nonce-keyed cache entry. `build-test` holds
`contents: read` only, blanks every credential variable, and installs strictly
from that transferred cache.

Every acquisition, packaging, and install path in that contract hardcoded the
single root lockfile: `Path("package-lock.json")` in the validator,
`lock_file=package-lock.json` in the packaging step, one `npm ci` in the install
step, and a script plan validated against one root `package.json`.
`cache-dependency-path` reaches only `actions/setup-node`'s cache key, so it
never widened acquisition.

The consequence is that a repository whose private dependencies are not all
reachable from the root lockfile has **no credentialless path at all**.
`Verjson/verjson-authn#252` is the live case: a
`self-contained-examples (catalog-google-login)` job installs
`examples/catalog-google-login/`, which has its own `package.json` and
`package-lock.json` and depends on the private
`@verjson/oidc-claims-middleware`. That job deliberately executes PR-authored
`npm ci` lifecycle scripts and `npm run verify` on a persistent self-hosted
runner (verjson-authn ADR-0046), so it is exactly the class of job that must
never hold a credential. Today it passes only when the runner's npm cache
happens to be warm and fails `E403 read_package` on a cold one.

## Decision

Extend the input contract with `secretless-nested-manifests`: a JSON array of
1–8 objects, each carrying **exactly** `path`, `approvedPackages`, and
`scriptPlan`. Nested manifests require `package-manager: npm`.

Three properties are load-bearing, and each is enforced rather than documented.

**1. Authorization is scoped to the manifest that declared it.** Every lockfile
is verified independently: its private package set must equal that manifest's own
`approvedPackages` exactly. A package approved for the root manifest is
unapproved inside a nested one, and the reverse holds too. There is no union, no
inheritance, and no workflow-call-wide allowlist. This is what keeps the blast
radius of a nested declaration equal to the packages the reviewer of that
declaration actually named — a nested `examples/` directory is often the least
reviewed part of a repository, so it must not be able to reach the production
manifest's approvals. Where a trusted repository policy is configured, each
manifest's `approvedPackages` must additionally be a subset of it.

**2. Declared paths are bounded and re-proved on the untrusted side.** A path is
a relative sequence of `[A-Za-z0-9][A-Za-z0-9._-]{0,63}` segments that must
resolve to a directory whose parents include the workspace, and must carry its
own `package.json` and `package-lock.json` — each also containment-checked after
resolution, because a PR-authored symlink satisfies every syntactic segment rule.
The credentialless job repeats that containment proof itself rather than trusting
the credentialed job's earlier one, since it reads the checkout at a later point.

**3. The credentialless job still receives zero package-read credential.** Nested
blobs join the *same* bounded transfer as the root's; nothing is fetched in
`build-test`. The transfer manifest gains one line,
`nested_manifests_sha256`, a digest over the ordered `path\tsha256(lock)` pairs,
so a nested lockfile swapped between acquisition and install fails the binding
check before npm is invoked. Each manifest then installs with
`npm ci --ignore-scripts --prefer-offline --no-audit --no-fund --cache <verified
cache>`. Nested manifests are always `--ignore-scripts`, which is strictly more
conservative than the root path.

Script plans follow the same scoping. Each `scriptPlan` is validated against the
`package.json` of the manifest that will run it and executed with that directory
as its working directory, so a nested plan cannot name a root-only script. The
protected candidate variant applies the same per-manifest `--chdir` inside its
bubblewrap namespace.

## Consequences

- `secretless-ci-script-plan` becomes optional when nested plans are declared;
  the script-plan step's `if:` now admits either input.
- The transfer manifest is 11 lines, not 10. The install step's exact line-count
  assertion moves with it, so a caller and a workflow at mismatched revisions
  fail closed rather than installing a partially bound cache.
- `Verjson/verjson-authn#252` becomes structurally satisfiable: acquisition,
  packaging, binding, install, and script execution all handle N manifests.
  Granting that job an org-wide `NODE_AUTH_TOKEN` — the alternative considered
  and rejected — would have put a package-read credential in a job that runs
  untrusted lifecycle scripts on a persistent runner, and is a regression of the
  boundary this workflow exists to hold.
- The 1–8 bound and the 8-entry nested script-plan bound cap the fan-out a single
  caller can ask a credentialed job to perform.
- Nested support is npm-only. A pnpm caller declaring nested manifests is
  rejected before any lockfile is parsed, rather than silently acquiring nothing.
- `.github/workflows/node-ci-protected.yml` is generated from `node-ci.yml`;
  both move together, and `scripts/ci-gate/node-ci-required-identity.test.py`
  repins to the committed source bytes.

Behavioral coverage lives in
`scripts/ci-gate/node-ci-secretless-nested-manifests.test.sh`, registered in the
`platform` group of `scripts/actions-ci-groups.tsv`. It includes the
cross-manifest smuggling controls in both directions, the aliased-declaration
case where two paths resolve to one directory, symlink escapes on both the
credentialed and credentialless sides, the post-acquisition lockfile tamper, and
an end-to-end two-manifest transfer and install.
