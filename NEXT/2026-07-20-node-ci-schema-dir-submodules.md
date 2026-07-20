# node-ci.yml gains schema-dir + submodules support — 2026-07-20

Closes #84; unblocks the schema/api/worker legs of #49. `node-ci.yml` did a
plain `checkout` + single root `npm ci`, so the node-flavored templates — which
consume their schema package as a **git submodule + `file:` dep** — couldn't
adopt it without red CI (the worker PM correctly blocked rather than land a
regression, verjson-worker-template#8).

Mirrors the fix `ui-ci.yml` already ships: new optional `schema-dir` input
(default `''` — empty keeps today's behavior), `submodules: recursive` checkout
with `token: ${{ secrets.submodules-token || github.token }}`, new optional
`submodules-token` secret, and a conditional `npm ci` in `schema-dir` (carrying
`NODE_AUTH_TOKEN`, since node-ci authenticates the registry via an env-var
`.npmrc`) before the root install. Back-compatible: existing callers with no
`schema-dir`/`submodules-token` are unaffected.
