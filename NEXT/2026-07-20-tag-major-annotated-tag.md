# Moving major tag is now annotated, matching the documented bootstrap — 2026-07-20

Fixes #61. `tag-major.yml` re-pointed the moving `vX` tag with `git tag -f`
(lightweight), while the documented bootstrap in
`docs/reusable-workflow-versioning.md` creates **annotated** tags (`git tag -a`)
like `v1.0.0`. The re-point now uses `git tag -f -a … -m …` so the moving major
tag carries a tagger/message and matches the release tags it tracks — no more
lightweight/annotated split across the `vX` and `vX.Y.Z` refs.
