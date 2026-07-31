# Read CI status through repository-scoped REST APIs — 2026-07-30

The shared merge gate now combines paginated check runs and commit statuses from
the immutable PR head instead of expanding the permission-sensitive GraphQL
`statusCheckRollup`. Green, red, pending, absent, startup-failed, and unreadable
states retain their fail-closed handling
([#248](https://github.com/Verjson/.github/issues/248), ADR 0037).
