# 0010 — Platform-template service repos consume org reusable workflows

- **Date:** 2026-07-19
- **Issue:** Verjson/.github#49 (migration tracking); Verjson/.github#31 (item 3, reusables)
- **PR:** per-conversion (one per service template repo; this ADR precedes them)
- **Category:** CI architecture (touches CI auth surface + runner topology — sensitive class)
- **Relationship:** builds on the reusable workflows `helm-ci.yml` (#40),
  `pulumi-ci.yml` (#46), `ui-ci.yml` (#48) and the `setup-verjson-node` composite (#36).

## Context

`verjson-platform-template` composes seven per-service submodules — each an
independently-owned template repo that **every new platform inherits verbatim**.
Their CI (`ci.yml.tmpl`) is hand-rolled and drifts: the helm template reinvents
`helm lint`/`helm template`, the infra template runs a generic node build with no
real `pulumi preview`, the UI template hand-wires a schema-submodule + build gate,
and schema/api/worker each re-implement the `NODE_AUTH_TOKEN` GitHub-Packages
dance (the same dance that bit `verjson-cli-cloud#59`).

Because the template is the source every platform starts from, this duplication is
inherited N times and can only be fixed N times — a bad property for CI that
touches the two things we most want centralised: **the registry/credential auth
surface** and **the runner the fleet points at**.

The org now provides that CI as reusable `workflow_call` workflows in
`Verjson/.github/.github/workflows` (helm/pulumi/ui), each dogfooding the
`setup-verjson-node` composite for auth and defaulting `runs-on` to the GCP
self-hosted pool in one place.

Ownership was confirmed with the verjson-cli PM: the platform/helm/infra templates
**and** the `.github` reusables are DevEx/`.github`'s domain, so this decision,
its PRs, and this record live here. (verjson-cli separately owns adopting the
composite on its `fix/ci-github-packages-auth` submodule *content*.)

## Decision

1. **Each platform-template service repo consumes the matching org reusable
   workflow** via `uses: Verjson/.github/.github/workflows/<lane>-ci.yml@main`,
   instead of hand-rolling the build/lint job:
   - `verjson-helm-template` → `helm-ci.yml`
   - `verjson-infra-template` → `pulumi-ci.yml`
   - `verjson-ui-template` → `ui-ci.yml`
   - `verjson-{schema,api,worker}-template` → pending a generic `node-ci.yml`
     reusable; until then they adopt the `setup-verjson-node` composite directly.
2. **`.tmpl` placeholders are carried through as `with:` inputs** (`{{name}}`,
   `{{nodeVersion}}`, `@{{scope}}`), so a rendered platform still gets correct
   per-project values.
3. **Each conversion is its own PR** against the service template repo, referencing
   #49 and this ADR, and **each repo's bespoke `validate.yml` (template-render
   check) is preserved untouched** — only the `ci.yml.tmpl` build/lint job is in
   scope. Bespoke, genuinely per-repo steps (e.g. a kind smoke test, a live DB
   matrix) are NOT folded into the reusable; the reusable-caller rule is to
   preserve bespoke steps.
4. **Sequencing:** `verjson-helm-template` converts first (it is clean on `main`).
   The infra/schema/api/ui submodules are mid-flight on verjson-cli's
   `fix/ci-github-packages-auth` branch; their conversions wait until that lands
   so the two efforts don't collide on the same files.

## Consequences

- CI for every new platform is defined once and inherited correctly; a fleet move
  or an auth-surface fix is a one-file change in `.github`, not an N-repo sweep.
- The registry/credential auth surface is centralised in `setup-verjson-node`
  (secrets read from job env, never persisted to the shared runner gitconfig) —
  the sensitive reason this is ADR-worthy.
- Reduced faithfulness risk is handled per-PR: adopting `helm-ci.yml` adds a
  kubeconform validation the template lacked, so the first conversion PR must
  confirm the rendered chart passes (or scope kubeconform per the caller rule) on
  real CI before merge.
- Callers now depend on `@main` of the reusables. Pinning reusables to a tag is
  tracked separately (#31 item 5); until then a breaking change to a reusable can
  reach every template at once — mitigated by the extract-tests that gate reusable
  changes in `actions-ci.yml`.

### Representative before→after (sensitive hunk: `verjson-helm-template/.github/workflows/ci.yml.tmpl`)

```diff
 name: CI
 on:
   push:
     branches: [main]
   pull_request:

 jobs:
-  lint-template:
-    runs-on: ubuntu-latest
-    steps:
-      - uses: actions/checkout@v4
-      - uses: azure/setup-helm@v4
-        with:
-          version: v3.16.3
-      - run: helm lint .
-      - run: helm lint . -f values-local.yaml
-      - run: helm template {{name}} . > /tmp/default.yaml
-      - run: helm template {{name}} . -f values-local.yaml > /tmp/local.yaml
+  helm:
+    uses: Verjson/.github/.github/workflows/helm-ci.yml@main
+    with:
+      release-name: {{name}}
+      lint-values: 'values-local.yaml'
+      template-values: 'values-local.yaml'
```

The runner moves from `ubuntu-latest` to the reusable's default (`[self-hosted,
GCP]`) and a kubeconform validation is gained; both are verified on the conversion
PR's own CI before merge.
