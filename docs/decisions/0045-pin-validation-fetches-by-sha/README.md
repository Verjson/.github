# 0045 — Pin validation fetches by SHA, so it proves immutability but not reachability

- **Date:** 2026-08-02
- **Issue:** [Verjson/.github#234](https://github.com/Verjson/.github/issues/234)
- **Refs:** ADR 0014 (reusable workflow versioning), ADR 0023, ADR 0042

## Context

`actions-ci` checked out with `fetch-depth: 0` so that `node-workflow-pins.test.sh`
could resolve co-located action dependencies at their pinned commits. Full history
was only ever a proxy for "the pinned objects are present", and #287 made the proxy
more expensive by widening this workflow's `paths:` triggers to
`.github/workflows/**`, `docs/**` and `README.md` — docs-only pull requests began
paying for the whole object graph.

Measured rather than assumed: the pin test touches exactly three git objects, all at
the checked-out tip, and the repository currently carries no
`Verjson/.github/…@<sha>` self-reference at all.

#234 bounds the checkout to `fetch-depth: 1` and has the test materialise each
pinned commit on demand with `git fetch --no-tags --depth 1 origin <sha>`.

## Decision

Pin validation obtains its objects by fetching the exact SHA from the origin, rather
than by requiring the whole history to be present locally.

An object the checkout cannot obtain — fabricated, rewritten out of the origin, or
unreachable because the runner cannot fetch at all — is a **failure**, never a skip.
"Cannot check" and "checked and invalid" must not be distinguishable by outcome, and
that property is asserted directly against a real shallow clone of a real origin.

## Consequences

**The accepted-SHA set widened, and this is the part worth recording.** Validation
moved from *"reachable from a branch or tag of `Verjson/.github`"* to *"any object in
the repository network"* — which includes `refs/pull` heads, fork commits, and
commits whose branch has since been deleted.

This is demonstrable, not theoretical. `df4a417489c2c284c983615258d59748b7e760ee`
(the head of PR #302, whose branch is deleted) is not advertised by
`git ls-remote --heads --tags`, so a `fetch-depth: 0` checkout would not contain it —
yet `git fetch --depth 1 origin <that-sha>` resolves it.

So the guard now proves:

- **Immutability — still yes.** Git objects are content-addressed and hash-verified
  on receive, so a pinned SHA cannot be substituted with different content.
- **Repo-reachability — no longer.** A pin naming a fork commit or an unmerged pull
  request head, which previously failed this check because the object was absent from
  a full clone, now resolves. `walk_uses_graph` then recursively scans content that
  never appeared in a reviewed diff of this repository.

The attacker prerequisite drops from "write access to `Verjson/.github`" to "open a
fork, then get a pin change merged". Code review of the pin change remains the
primary control, and it was always the control that mattered — the previous behaviour
blocked fork SHAs incidentally, as a side effect of what a full clone happens to
contain, not by design. Recording it here so that a future reader does not mistake
the old behaviour for a deliberate reachability guarantee, and so that anyone who
wants that guarantee back knows it must be built explicitly (verify the SHA is an
ancestor of a protected ref) rather than assumed.

Measured cost, `github.com/Verjson/.github`, three runs each: full history
1,392,544 B / 1,995 objects / 1.13–1.37 s, versus depth-1 with tags 711,505 B /
521 objects / 1.06–1.13 s — 48.9% less transferred, 73.9% fewer objects, and the gap
widens with every commit.

`fetch-tags: true` is required alongside the bound: `doc-tag-pins.sh` reads `git tag`,
and a bounded fetch drops tags by default, which would turn every documented pin into
a lookup fault.

## Rollback

Restore `fetch-depth: 0` in `.github/workflows/actions-ci.yml` and drop
`fetch_pinned_commit` from `scripts/node-workflow-pins.test.sh`. The fail-closed
assertions stay valid either way — they assert an unobtainable pin fails, which is
true under both mechanisms. Reverting reinstates reachability-by-accident and the
full-history cost together; if only the reachability property is wanted, supersede
this record with one that verifies ancestry explicitly.
