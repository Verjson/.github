# Point moving major tags directly at release commits — 2026-07-21

Peel each annotated `vX.Y.Z` release tag to its commit before creating the
annotated moving `vX` tag. This removes the unnecessary tag-of-a-tag chain while
preserving the published release and moving-major semantics from ADR 0014.
Closes #73.
