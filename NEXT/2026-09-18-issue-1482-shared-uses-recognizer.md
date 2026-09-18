---
date: 2026-09-18
issue: 1482
title: One shared definition of what a contract reference is
impact: patch
---

`scripts/contract-version.py` and `scripts/fleet-contract-inventory.py` each carried their
own `uses:` pattern, and the two drifted. #1472 taught the first to read a pathless
root-action pin and did not change the second, so at `aa9d386` the line
`    uses: Verjson/.github@<40-hex>` was a reference to one tool and invisible to the
other — `contract-version` returned `(path=None, ref=<sha>)` and the inventory returned
nothing at all. An inventory that reports fewer references than exist is wrong in the
safe-looking direction: a repository carrying a root-action pin looks clean.

What a reference *is* now has one definition, `scripts/contract_reference.py`, and both
sweeps import the same compiled object. The fix is the shared definition rather than a
second hand-edit bringing the copies back into step, because two hand-maintained copies is
the condition that produced the drift; editing both resets the clock without removing the
mechanism.

The two sweeps were **not** unified wholesale, because they do not have the same job in
one respect. `contract-version` wants every reference: an unpinned one is precisely the
finding it reports. The inventory wants only the pinned ones, because its row is
`(repo, file, upstream path, pinned SHA)` and it resolves an upstream tree *at that SHA* —
a `@main` ref has no tree to resolve and no SHA for the column. That narrowing survives as
`pins()`, a filter over the shared recognizer, rather than as a second pattern with the
filter baked into its character classes. A filter cannot drift from the definition it
filters. The four axes the two patterns actually differed on were the path segment
(divergence, fixed), the ref class (the legitimate difference, now a filter), the
whole-text application, and the delimiter anchor.

The whole-text application was the second axis #1482 names, and it is resolved as a
defect. `\s*` after the key spans a newline, so the inventory's pattern run over un-split
text let a bare `uses:` on one line take the *next* line's hub reference as its value.
Both sweeps now read per line. In the YAML the inventory fetches — it lists
`.github/workflows` and nothing else — a `uses:` key and its value are on one line; two
lines that only look adjacent are not a reference.

Making the pathless pin visible was half of it. The inventory resolves an upstream blob at
the pinned SHA, and `path=None` is a key in no tree, so `resolve_path` sends a pathless
reference to the root action GitHub itself would resolve, trying `action.yml` then
`action.yaml`. This repository carries neither today, so such a reference classifies
UNKNOWN — the fail-closed answer the rest of the sweep is built on — rather than being
attributed to some other file. Its row prints `<root-action>` in the path column, a marker
rather than a file name, because which of the two names it would resolve to depends on the
tree being compared.

The agreement is asserted by identity — `fci.USES_RE is cv.USES_RE` — not by running a
fixture list through both. A fixture list pins the shapes it happens to name; identity
means a second copy cannot be reintroduced at all without the test failing.

Six pre-existing inventory tests moved from `USES_RE.finditer(...).group("sha")` to
`pins()`, which is where the narrowing now lives. Their inputs and expected outcomes are
unchanged. Two of them gained an assertion rather than losing one: a `@v1` ref and a
64-hex ref are each still *seen* as references — that is what lets `contract-version`
report them — while remaining absent from `pins()`. The 64-hex boundary is now `SHA_RE`'s
anchoring instead of a `(?![0-9a-f])` lookahead inside the pattern.

`scripts/ci-gate/fleet-contract-inventory.test.py` went from 42 tests to 47, all green;
`scripts/ci-gate/contract-version.test.py` holds at 81 green across the move.
`scripts/actions-ci-group.sh platform` passed 85 commands, exit 0, with no
`::error::group=` line.
