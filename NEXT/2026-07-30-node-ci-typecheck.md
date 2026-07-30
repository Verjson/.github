# Enforce declared Node typechecks in reusable CI — 2026-07-30

The reusable Node CI workflow now runs a caller's `typecheck` script when
present, closing the org-wide type-test gap without breaking repositories that
do not define the script. Fixes #190.
