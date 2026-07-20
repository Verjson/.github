# actionlint deterministically lints the workflows — 2026-07-20

Phase 1 of #43 (issue #80). Adds `.github/workflows/actionlint.yml`, which runs
`actionlint` over `.github/workflows/**` on every workflow-touching PR — catching
the nit classes the merge-gate AI reviewer used to flag by hand (deprecated/
inconsistent action pins like #60, workflow-expression errors) deterministically
and for free, pre-review. actionlint is installed as a **pinned release binary**
(v1.7.7) rather than a container action, because the GCP self-hosted pool has no
Docker socket.
