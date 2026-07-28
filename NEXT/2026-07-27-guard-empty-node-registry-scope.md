# Keep public Node installs on npmjs — 2026-07-27

Reusable Node CI and release workflows now leave `actions/setup-node`'s
`registry-url` empty when callers set `scope: ''`, preventing public-only
installs from being redirected to GitHub Packages. The default `@verjson`
private-registry authentication and explicit npm cache controls remain intact
(#155).
