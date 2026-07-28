# Cache and bound reusable Node workflows — 2026-07-27

Added configurable 30-minute job bounds and lockfile-keyed npm download caching
to `node-ci`, `node-release`, and `setup-verjson-node`, with a cold-cache restore
probe and caller concurrency guidance. Private registry auth, schema/DB setup,
eligibility checks, and locked release tooling remain regression-covered
(#152).
