# Make CI status pagination runner-compatible — 2026-07-30

The merge gate now streams paginated REST responses through `jq` instead of
requiring a newer `gh api --slurp`, and reports bounded endpoint/shape diagnostics
when status aggregation fails closed. Fixes #248 and unblocks #249.
