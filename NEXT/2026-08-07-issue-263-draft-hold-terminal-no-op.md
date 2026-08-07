---
date: 2026-08-07
title: Report a draft or held PR as a terminal no-op instead of a red privileged merge
issue: 263
---

`ai-privileged-merge.yml` fired on drafts and died with `::error::PR is draft` and exit 1, so
every pull request that followed this repository's own guidance — open non-trivial work as a
draft while an out-of-band review runs — carried a red `privileged_merge` check for as long as
it stayed a draft. A `hold` / `DO NOT MERGE` label did the same. Both are now terminal no-ops
with a notice naming the remedy, the shape ADR 0037 already established for the
workflow-files hold.

A held PR that reports failure and one that reports success are both "not merged". Only the
first teaches reviewers that red is normal — the erosion #341 records from a different cause.

**The literal fix this issue proposed would have introduced a fail-open**, which is the part
worth carrying forward. The old form was:

```sh
jq -e '.isDraft | not' <<<"$meta" || { echo "::error::PR is draft"; exit 1; }
```

That is fail-closed only *incidentally*: a jq error on malformed or truncated metadata takes
the same branch as a real draft, and the branch exited non-zero. Switching it to `exit 0`
would have turned an unreadable hold signal into a silent success on the one workflow holding
`ORG_ADMIN_TOKEN` — #480's defect, freshly introduced while fixing something else. So the
signals are materialised into strings with **three** states, and unreadable is an error,
distinct from both held and not-held.

`.isDraft` is checked by **type**, not truthiness. jq's `if` treats every non-null non-false
value as true, so `"isDraft": "maybe"` was absorbed as a hold and reported as a deliberate
human stop. Not merging is the safe direction, but relabelling unreadable metadata as "a human
held this" is the same category of misreport. The test caught this in my own first fix, before
it shipped.

Coverage lives in `scripts/ci-gate/entry-workflow-provenance.test.sh`, which already extracts
and executes this step's `run:` block. Asserted two-sided, since either half alone admits a
wrong fix: a held PR must not merge **and** must not fail; an unreadable signal must not merge
**and** must not pass as a hold. The existing positive control — a legitimate run still merges
— is what stops the set from passing by refusing everything. Rationale is in the
[2026-08-07 amendments to ADR 0012](docs/decisions/0012-gate-honors-do-not-merge-label/README.md).
