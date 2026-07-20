# node-ci.yml caller-doc: document the required packages:read permission — 2026-07-20

Follow-up to #86. A `node-ci.yml` caller must set `permissions: {contents:
read, packages: read}` on its job — a reusable workflow's `GITHUB_TOKEN` is
capped by the caller, so the reusable's own `packages: read` doesn't take effect
unless the caller grants it, and `npm ci` 401s on private `@scope/*` deps
otherwise. The verjson-ui-template migration hit this concretely (its gate
flagged the 401); documenting it in the caller example stops every future
node-ci.yml consumer from rediscovering it. Docs-only.
