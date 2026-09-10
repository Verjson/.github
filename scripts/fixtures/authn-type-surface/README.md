# Protected package policy regression fixture

`package-policy.json` records `Verjson/verjson-authn`'s
`CI_SECRETLESS_PACKAGE_POLICY` as read through authenticated GitHub APIs on
2026-09-10. Consumer main was `3160f49782ea17632b19122873466b5c5556b0e2`.
Its type-surface caller requested `@verjson/authn` 2.0.0 and its auxiliary pin was
`63a0bb826eb0b707da5e592f7fd4070627ec71ab`.

This fixture guards the package-policy admission failure from required run
`34425797400`. It is regression evidence, not a live policy source or authorization
to alter the consumer variable. ADR 0168 records the exact pinned validator trial.
