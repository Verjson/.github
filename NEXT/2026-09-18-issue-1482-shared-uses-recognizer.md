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

The agreement is asserted by identity, not by running a fixture list through both: the
inventory reads `cv.USES_RE` itself and calls `contract_reference`'s own `references` and
`pins`, so no copy of them can sit on the path either sweep takes. That is narrower than
what an earlier draft of this fragment claimed. It said identity meant "a second copy
cannot be reintroduced at all without the test failing", and that was false as written:
the assertion was on `fci.references.__globals__["USES_RE"]`, which reads
`contract_reference`'s module dict only while `fci.references` *is* the shared function.
A behaviourally identical private copy reintroduced into `fleet-contract-inventory.py`
made the lookup read that module's globals instead — where `USES_RE` is still the shared
import — and survived the whole suite. Measured, then fixed: the assertions now name the
functions, and that identical copy dies on them.

Six pre-existing inventory tests moved from `USES_RE.finditer(...).group("sha")` to
`pins()`, which is where the narrowing now lives. Their inputs and expected outcomes are
unchanged. Two of them gained an assertion rather than losing one: a `@v1` ref and a
64-hex ref are each still *seen* as references — that is what lets `contract-version`
report them — while remaining absent from `pins()`. The 64-hex boundary is now `SHA_RE`'s
anchoring instead of a `(?![0-9a-f])` lookahead inside the pattern.

`scripts/ci-gate/fleet-contract-inventory.test.py` went from 42 tests to 47 at this step
and to 52 with the flow-style fix below, all green; `scripts/ci-gate/contract-version.test.py`
held at 81 green across the move and stands at 86. All three CI-equivalent groups pass:
`platform` 85 commands and 1607 TAP `ok`, `merge-gate` 59 commands and 737 `ok`, and
`changelog-release` 62 commands and 666 `ok` — each exit 0, with no `not ok` and no
`::error::group=` line. The `ok` counts are TAP from the shell gates; the Python suites
these changes touch report `Ran N tests` instead and contribute none of them, which is why
adding Python tests to `platform` leaves 1607 unchanged — `aa9d386`, this branch's merge
base, measures 1607 as well.

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

Measured on this repository's own tracked corpus rather than on the fleet, over the 1388
tracked files the scan actually reads: they carry 136 `uses:` references under the
previous pattern and 140 under this one. **13** of the 136 ended in an absorbed backtick
before the backtick fix, in `NEXT/` fragments, two ADRs,
`docs/reusable-workflow-versioning.md`, and the scan's own sources and tests; 3 of the 13
are prose this branch itself adds. An earlier draft said 12 and listed the refs they carry
as `main`, `v1`, `v2.2.0` or a `<sha>`/`<40-hex>` placeholder; at the shipped tree it is 13
and one of them carries `v2`, which that list omits. The property that actually matters
survives the correction and was re-measured: **none of the 13 is a 40-hex SHA**, so #1483
stays latent on this corpus exactly as filed — it bites when a doc or a consumer fixture
first quotes a real contract SHA in inline code.

That is a measurement of one repository. The live fleet was swept separately, over the
`.github/workflows` listing the inventory actually reads: **96** repositories, 0
unreachable, **337** pinned references under the previous pattern and **337** under the
shipped one, `gained=[]` and `lost=[]`. #1482's body and this fragment previously said
95; 96 is what `gh repo list Verjson --no-archived` returns today, and the count is a
live figure rather than a fixed one. A whole-corpus re-measurement of the fleet — every
tracked file, as `references()` reads them, rather than the workflow listing — was still
not run, because it means fetching whole trees for 96 repositories.

On this repository's own tracked corpus at the tree this fragment ships with, the previous
pattern reads 136 references and the shipped one 140. The four the previous pattern cannot
see are the flow-style fixtures and prose this branch itself adds — the shapes being fixed,
appearing in the fix's own sources. The count that carries a verdict is the 40-hex one: 18
before and **21** after. Those three are pre-existing source-string fixtures in
`scripts/cli_projects_package_surface_test.py` and `scripts/required-checks-audit.test.sh`
whose pins the previous pattern read as 41 characters, ending in `\` and `n`. They are the
first instances of #1483's muting that carry a real 40-hex value rather than a placeholder,
and they were invisible until this fix.

## The unification narrowed the inventory's accept set, and that is fixed here (#1482)

Giving both sweeps one recognizer moved the inventory onto a ref class it had never used,
and that class is wider than the pattern it replaced in a way that *loses* pins. The
pattern the inventory carried before required exactly 40 hex and closed on
`(?![0-9a-f])`; the shared one read any ref out of a class that ran straight through the
YAML flow indicators. So a step written in flow style —

    steps: [{uses: Verjson/.github/.github/workflows/node-ci.yml@<40-hex>}]

— which is ordinary YAML that parses to exactly the block-style structure, and lives in
the `.github/workflows/*.yml` that is the whole of what the inventory reads, yielded the
ref `<sha>}]`. `SHA_RE` rejects that, so `pins()` returned nothing where the replaced
pattern returned one pin. Measured before the fix: **1** against **0**. That is the muting
direction — a repository carrying a pin looks clean — which is the failure this module's
own docstring says it exists to prevent, reached this time by unifying two recognizers
rather than by letting them drift.

Two independent causes sat on the one line, and both are fixed. The delimiter class did
not admit `{`, so a key opening a flow mapping was not a key at all; it now admits `{`,
`[` and `,`, which is where YAML begins a key rather than where it ends a value. And the
ref class did not stop at `}`, so the ref overran; the ref now matches a 40-hex run as a
whole alternative closing on `(?![\w./+@-])`, which is the replaced pattern's boundary
restored and widened. Widened, because `(?![0-9a-f])` alone would report a tag named
`<40-hex>-rc1` as a pin at its first 40 characters — inventing a PIN_MISMATCH, which is
the direction strictly worse than muting.

The rationale for that lookahead was wrong in an earlier draft, and the wrong version hid
a live case. It said a 40-hex run is a whole ref exactly when the next character cannot
continue a refname, "which covers `}`, `]` and `,`". `git check-ref-format` accepts
`refs/tags/<40-hex>}foo`, `]foo`, `,foo` and `{foo`, so those are precisely characters
that *can* continue a refname; the lookahead works because they are YAML structure in the
files this scans, which is a judgement about context rather than a fact about refnames.
Read correctly, the lookahead enumerates the characters treated as ref-continuing — and
`@` was missing from it. `<40-hex>@2` is a legal tag, and the scan read its first 40
characters as a pin, inventing a PIN_MISMATCH against a SHA nobody wrote. `@` is in the
class now and **that instance** is closed rather than documented; a test pins `/b`, `+b`,
`@2`, `-rc1` and `.1` all falling through to the general class.

The class it belongs to is not closed, and what remains open is a **complement, not a
list** — naming a finite remainder would repeat, in one paragraph, exactly the mistake the
paragraph is about. Because the 40-hex alternative is tried first, every character outside
`[\w./+@-]` that git permits in a refname reproduces the identical invented pin:
`git check-ref-format refs/tags/<40-hex><c>2` exits 0 while the recognizer reports a pin at
the first 40 characters. `%`, `&`, `;`, `!`, `=`, `(`, `)`, `#`, `<`, `>` and `|` are
examples of that, not the extent of it — 19 printable ASCII characters qualify, including
`"`, `'` and a backtick, which the *general* class excludes and which therefore reach this
alternative anyway. Outside ASCII it is not a finite set at all: all 2551 non-word,
non-space characters tested across U+00A0–U+20FF behave identically. `@` is the one
character the fix closed.

An earlier revision of this fragment named eleven characters as though they were the
remainder. That was wrong by 8 in ASCII alone and unboundedly wrong beyond it, and the
reason is worth keeping: **enumerating what a deny-list still admits is itself a
deny-list**, and inherits the same unboundedness. The limit is recorded in
`scripts/contract_reference.py` beside the `{`/`}`/`,`/`]` limit. It is not closed by
adding more characters, because no finite number of them closes it; the closure is
inverting to an allow-list of the shapes a pin may take rather than a deny-list of the
characters that may follow one.

The general class still admits `{`, `}`, `,` and `]`, and that is measured rather than
assumed — re-measured at this tree, because the earlier figures were taken at `6d60385`
and shipped against a larger corpus: excluding them drops 27 of this repository's 140
references outright and truncates 10 more, 8 of those to `$`, because the corpus writes
refs as `@${ref}` and `@{PIN}` substitutions in generator and fixture sources. A *non*-SHA
ref in flow style is therefore still quoted back with its trailing `}]` attached. That is
the noisy direction, not the muting one — an unpinned ref is reported unpinned either way
— and it is left named rather than closed by enumerating punctuation the corpus proves is
load-bearing elsewhere.

The ref class also excludes a backslash now, the closing half of the `\n` the delimiter
class already reads as an opener. On this corpus that alone corrects 30 refs that came
back with a trailing `\` and `n`, 28 of them ending in a literal `\n`. It recovers no pin
at this tree, and an earlier draft's "**3** of which were 40-hex pins" is stale rather
than wrong: the flow-style fix in this same branch made the ref stop after 40 hex
characters, so the backslash no longer reaches a pin. Against the pattern as it stood
before that alternative existed, the backtick and backslash exclusions together recovered
3 pins, and that is the only pattern the figure is true of. This is the same subsumption
that hid the backtick and single-quote exclusions from the suite.

This is latent, not active, and the claim was re-scoped to what was actually measured. The
live fleet sweep measures `gained=[] lost=[]` over the `.github/workflows` listing the
inventory reads. But `contract-version` scans every tracked file, so the delimiter
widening was re-measured there too: over all 1388 it gains 4 references and loses none —
a `<40-hex>}]` placeholder in `contract_reference.py` and in this fragment, and two `{B}`
fixture refs in the inventory's suite — and none of the 4 is a 40-hex pin. So "costs
nothing" is a statement about this tree, not a general one. `{`, `[` and `,` also precede
a `uses:` key inside a `--jq` body, inside `fromJSON('{...}')`, and after a comma in
ordinary prose, and a 40-hex run in one of those would now read as a pin where it read as
nothing before. That is the inventing direction, so it is named here rather than waved
off: no such line is in the tree today, and the cost is latent, not absent.

`scripts/ci-gate/contract-version.test.py` went from 81 tests to 92 and
`scripts/ci-gate/fleet-contract-inventory.test.py` from 42 to 52, all green.

One further finding came out of mutation-testing the result: the 40-hex alternative
*subsumes* #1483's backtick exclusion for pinned refs, because the ref now stops after 40
characters and never reaches the closing backtick. Re-admitting the backtick left every
test green. The exclusion is still the only thing doing the work for a ref that is not a
SHA, so `UsesShapeCoverage.test_two_adjacent_backtick_refs_are_two_references_when_unpinned`
pins it there, on `@v1`/`@v2` written adjacently so the two spellings differ in the number
of matches rather than in one ref's content. The same argument and the same shape pin the
backslash.
