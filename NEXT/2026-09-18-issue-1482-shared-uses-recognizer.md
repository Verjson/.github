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

## A backtick-delimited pin is now read as a SHA (#1483)

The ref class was `[^\s"']` — whitespace and the two quotes, but not a backtick. The key
anchor reads a backtick as a string opener, so a pin written as Markdown inline code or as
a template literal absorbed its own closing backtick: the ref came back 41 characters, a
correct and immutable 40-hex pin that could never compare equal to a release commit, and
the verdict was `UNPINNED_REFERENCE` on a line that is in fact pinned. That is the muting
direction ADR 0185 names, on the same shapes #1472 widened the recognizer to read. The
class now excludes a backtick too.

This is the first edit to land on the shared definition #1482 created, and it is one edit:
the inventory's own pattern would have needed the same correction separately under the
previous arrangement, and nothing would have said so.

`UsesShapeCoverage.test_a_pin_inside_a_backtick_literal_is_still_read` asserted the defect
— the `UNPINNED_REFERENCE` verdict and the absorbed backtick in the detail string — so
changing it is the visible, deliberate part of this fix rather than a silent relaxation. It
now requires `PIN_MISMATCH`, which is the true statement about that fixture: the pin is
read, and it is not the tracked release commit. Before the class changed, it failed with
`['UNPINNED_REFERENCE'] != ['PIN_MISMATCH']`.

The boundary is pinned on both sides, and the narrowing side needs two instances to be
pinned at all. With one backtick-delimited pin on a line, admitting and excluding the
backtick differ only in the content of a single ref. Written adjacently, with no
whitespace to stop the ref on the pattern's behalf, they differ in the number of matches:
admitting it yields **one** match whose ref runs through the closing backtick into the
second reference as `` <sha-a>``uses: ``, and excluding it yields **two** clean refs. That
count is what a single-instance fixture cannot assert. On the widening side, a ref
carrying `.`, `-` and `+` — `@v2.2.0-rc.1+build` — must still survive whole, so an edit
that over-narrows the class by one more character reddens.

Measured on this repository's own tracked corpus rather than on the fleet: 1388 tracked
files carry 124 `uses:` references, and 124 both before and after — the fix changes what a
ref *is*, not how many there are. **12** of them ended in an absorbed backtick before the
change, in `NEXT/` fragments, two ADRs, `docs/reusable-workflow-versioning.md`, and the
scan's own sources and tests; 3 of those 12 are prose this branch itself adds. The number
of references that read as a 40-hex SHA is **18** before and **18** after, so no verdict on
this corpus changes today: every one of the 12 carries `main`, `v1`, `v2.2.0`, or a
`<sha>`/`<40-hex>` placeholder. The defect stays latent until a doc or a consumer fixture
quotes a real contract SHA in inline code, which is what it was filed as.

That is a measurement of one repository, not of the 95-repository fleet #1483 scopes.
`references()` reads every tracked file, so an end-to-end corpus re-measurement means
fetching whole trees rather than the `.github/workflows` listing the inventory sweep needs,
and that was not run here.

`scripts/ci-gate/contract-version.test.py` went from 81 tests to 83, all green.
