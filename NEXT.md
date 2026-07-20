<!--
  This file is a static pointer — do NOT add changelog entries here.

  To avoid the merge conflicts that a shared, prepend-only changelog causes when
  several PRs are in flight, this repo keeps its running log as one file per
  entry under NEXT/. Add your entry as a new fragment; you never touch a shared
  file, so two PRs can never conflict on the log.
-->
# NEXT — running log (fragment-based)

The running log lives in [`NEXT/`](NEXT/) as one markdown file per entry.

- **Add an entry:** create `NEXT/YYYY-MM-DD-<slug>.md` in the same commit as your
  change (see [`NEXT/README.md`](NEXT/README.md) for the format). Do not edit this
  file or any other shared changelog — that is the whole point.
- **Read the whole log, newest first:** `scripts/render-next.sh`.
- History prior to the fragment split lives in
  [`NEXT/0000-archive.md`](NEXT/0000-archive.md).
