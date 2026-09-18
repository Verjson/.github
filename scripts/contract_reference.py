#!/usr/bin/env python3
"""What a `Verjson/.github` contract reference *is* -- one definition, two sweeps.

`scripts/contract-version.py` checks one repository's references and
`scripts/fleet-contract-inventory.py` sweeps the fleet's. They each carried
their own `uses:` pattern, and the two drifted: #1472 taught the first to read a
pathless root-action pin and the second was not changed, so the same line was a
pin to one tool and invisible to the other (Verjson/.github#1482). An inventory
that reports fewer references than exist is wrong in the safe-looking direction
-- a repository carrying a root-action pin looks clean.

The two sweeps genuinely differ in one respect, and only one. This module draws
that line explicitly so it cannot be mistaken for drift again:

* **What a reference is** is shared, and is `USES_RE`. A reference is a `uses:`
  key naming the hub with an optional path segment and *any* ref. This is the
  whole of what "reference" means, and neither caller may narrow it privately.
* **Which references a caller cares about** is the caller's own business.
  `contract-version` wants every reference, because an unpinned one is precisely
  the finding it reports. The inventory wants only the pinned ones, because its
  row is `(repo, file, upstream path, pinned SHA)` and it resolves an upstream
  tree *at that SHA* -- a `@main` ref has no tree to resolve and no SHA to put in
  the column. That narrowing is expressed here as `pins()`, a filter over the
  shared recognizer, rather than as a second pattern with the filter baked into
  its character classes. A filter cannot drift from the definition it filters.

Both callers apply the pattern per line. See `references()` for why the
whole-text application the inventory used is not merely equivalent.
"""
from __future__ import annotations

import re

# Anchored on the hub, so an adopter's own SHA-pinned third-party actions are not
# contract references. Case-insensitive because GitHub resolves owner/repo that
# way and a completeness check must not drop a lowercase reference.
# The optional quote is not cosmetic: `uses: 'Verjson/.github/x.yml@<sha>'` is
# valid, common YAML, and an unquoted-only pattern reports a skewed quoted pin as
# no finding at all -- a clean PASS on exactly the skew this check exists to catch.
# The key itself is matched loosely for the same reason as the value quote:
# `"uses": x` and `uses : x` are both legal YAML that Actions accepts, and a
# pattern keyed on the literal `uses:` reads a pin written either way as no
# reference at all. Neither shape occurs anywhere in the fleet measured for
# #1433, so this widens the recognizer without changing a single verdict on it.
# The path segment is optional because `uses: Verjson/.github@<sha>` names the
# repository's own root action, which is a reference with a perfectly readable
# pin. Requiring the segment reported it as a gap reading "no path@ref this scan
# can read" -- a false gap on a correct, immutable pin, which is the direction of
# error ADR 0185 calls muting. The leading `/` stays inside the optional group,
# so `Verjson/.github-mirror@<sha>` still matches nothing: the character after
# the hub name is either `/` or `@`, never arbitrary text.
# The ref class excludes a backtick as well as whitespace and the two quotes,
# because the key anchor above reads a backtick as a string opener and the value
# has to end where that string does. It did not until Verjson/.github#1483:
# `` `uses: Verjson/.github/x.yml@<40-hex>` `` absorbed its own closing backtick
# and yielded a 41-character ref, so a correct, immutable pin never compared
# equal to a release commit and the verdict was UNPINNED_REFERENCE on a line
# that is in fact pinned -- the muting direction ADR 0185 names, on the same
# inline-code and template-literal shapes the backtick anchor was widened to
# read. The exclusion is pinned from both sides: a ref carrying `.`, `-` and `+`
# must still survive whole, and two backtick pins written adjacently must be two
# matches rather than one, which is the assertion a single-instance fixture
# cannot make.
# The class excludes a backslash too, which is the closing half of the `\n` the
# delimiter class already reads as an opener. A source-string fixture
# `f"jobs:\n  ci:\n    uses: Verjson/.github/x.yml@{sha}\n"` ends its value where
# it ends its line, and until this it did not: the ref came back with the two
# characters `\` and `n` on the end. That cost 25 of this repository's own 123
# references a corrupted ref and 3 of them their pin outright -- a 40-hex SHA
# read as 41 characters is the same muting as the backtick above, reached by a
# different character. `\` is also what `git check-ref-format` forbids in a
# refname, so nothing legitimate is lost.
# The ref admits a 40-hex SHA as an alternative *before* that general class, and
# that alternative alone is what makes a pin readable in flow-style YAML.
# `steps: [{uses: Verjson/.github/x.yml@<40-hex>}]` is ordinary YAML, parses to
# exactly the block-style structure, and lives in the `.github/workflows/*.yml`
# that is the whole of what the inventory reads; the general class runs straight
# through the `}` and `]`, yields `<sha>}]`, fails `SHA_RE`, and the pin is
# invisible to `pins()` -- muting, and muting the single pattern this module
# replaced did not do, because it required exactly 40 hex and closed on
# `(?![0-9a-f])`. That boundary is restored and widened to `(?![\w./+-])`: a
# 40-hex run is a whole ref when the next character cannot continue a refname,
# which covers `}`, `]`, `,` and anything else structural without naming them.
# Widening it past `(?![0-9a-f])` is the part that is not merely restoration --
# it keeps a tag named `<40-hex>-rc1` or `<40-hex>.1` falling through to the
# general class rather than being reported as a pin at its first 40 characters,
# which is the inventing direction and worse than the muting one.
# The general class still admits `{`, `}`, `,` and `]`, and deliberately: this
# corpus writes refs as `@{PIN}` and `@${ref}` substitutions in generator and
# fixture sources, and excluding those characters drops 19 of the 123 references
# entirely and truncates 7 more to `$`. So a *non*-SHA ref in flow style is
# still quoted back with its closing `}]` attached. That is the noisy direction,
# not the muting one -- the verdict on an unpinned ref is unpinned either way --
# and it is left rather than fixed by enumerating punctuation the corpus proves
# is load-bearing elsewhere.
# The ref admits a whole `${{ ... }}` expression as one unit. Such a ref is still
# UNPINNED_REFERENCE -- the verdict was never in question -- but `[^\s"']+` alone
# stops at the expression's first space and quotes the offending ref back as
# `${{`, which is not a thing anyone wrote. The expression branch is lazy to its
# own `}}`, and its class excludes `}` so it cannot run past the value into the
# rest of the line. The `\n` in that class is belt-and-braces and deliberately
# unasserted: `references()` scans `splitlines()` output, so no line it is given
# contains a newline and no test can distinguish removing it. It is kept because
# the class should read as line-bounded wherever else the pattern is reused.
# The `{0,200}` bound is what keeps the scan linear, and it is load-bearing
# rather than tidy. An unbounded `.*?` re-scans the line tail for a `}}` from
# every `$` position, so a line dense with *unterminated* `${{` costs O(n^2):
# measured 53ms at 1600 openers, 833ms at 6400, 13.1s at 25600, and over 120s at
# 102400, against a `MAX_SCAN_BYTES` of 1 MiB and a scan that reads every tracked
# file -- one minified or templated line would stall a fleet sweep for minutes.
# Atomic grouping does not help, because the failing scan is itself O(n) per
# start. The bound costs only that an expression longer than it falls back to the
# plain class; the longest in the measured fleet is far shorter.
# The key is matched case-*sensitively*, scoped with `(?-i:...)` so the trailing
# `re.IGNORECASE` still case-folds the hub name that GitHub itself case-folds.
# Without that scoping the flag also covered the key literal, and the pathless
# form then read `- Uses:` in an English list item as a pin -- inventing a
# PIN_MISMATCH, which is strictly worse than the false *gap* the rationale on
# `USES_KEY_RE` -- which lives in `scripts/contract-version.py`, not here, and
# stayed there because only that sweep reports gaps -- exists to prevent.
# The key is anchored to a *delimiter* rather than to the line start. A pin this
# scan must read is written in one of four positions: at the start of its line,
# after a quote or backtick that opens it as a string or inline-code value,
# after the `#` of a commented-out pin, or after a literal `\n` escape inside a
# source-string fixture such as `f"jobs:\n  ci:\n    uses: ..."`. The delimiter
# need not be adjacent to the key: `[ \t]*` and an optional `- ` bullet may sit
# between them, so a quote followed by a space is admissible too. What separates
# a key from prose is therefore not that a delimiter can never precede a
# mid-sentence `uses:` -- it can -- but that one which does must still be
# followed by a literal `Verjson/.github@<ref>` on the same line.
# Anchoring to the line start instead -- `^\s*(?:-\s+)?` -- is far too blunt, and
# the earlier rationale for rejecting it was wrong about why. It drops 181
# references across the measured fleet, but classifying those 181 lines gives 108
# `.sh` grep-assertion and fixture literals, 43 `.py`/`.ts`/`.js`/`.mjs` fixture
# string literals, 21 `.md` prose and ADR diff fragments, and only 9 comment
# lines -- of which 8 are the usage-example headers in this repository's own
# reusable workflows and 1 is a prose comment in this file. So the cost is
# overwhelmingly test scaffolding, not pins; and the span-exclusion double-count
# the header pass guards against does not arise in any of them, because all 9
# comment drops carry a non-SHA ref (`@main`, `@v2.2.0`, `@<placeholder>`) that
# `HEADER_RE` never matches. The real objection to line anchoring is simply that
# it cannot read a value written inside a string, which is most of what the fleet
# has.
# The delimiter form drops 5 references against the unanchored form on the same
# 96-repository corpus and adds none: four `+    uses: ...@main` diff fragments
# quoted inside frozen ADR records, and one `jobs.<job>.uses: ...@<placeholder>`
# documentation template. None is a live pin, so dropping them is a gain -- and
# 3 of the 5 are ADR records in this repository, which nothing runs this scan
# against, so the cost borne by consumers is 2, one each in `agents` and
# `verjson-agents`. Adding `+` to the delimiter class would recover the four and
# was rejected. The class does accept `- `, which carries the identical
# lowercase residual, so the asymmetry needs its own reason rather than the
# bullet hazard alone: `- ` is YAML sequence syntax, and a composite-action step
# writes a live pin as `- uses: ...`, so the scan must read it. `+` opens no
# YAML node -- it is only a diff marker or a Markdown list bullet -- so admitting
# it would buy documentation illustrations and nothing else, while reopening the
# `- Uses:`-shaped prose hazard on the one side the case-sensitivity scoping
# does not cover.
# Delimiter anchoring is what closes the residual the pathless form would
# otherwise have inherited: a lowercase `uses:` mid-sentence with no delimiter
# before it is now rejected in *both* shapes, pathless and path, so the new
# form is strictly better than the
# one the scan has always had rather than merely no worse. It also makes the
# lookbehind that previously rejected a longer key ending in `uses`, such as
# `statuses:`, redundant for that case: every position this class admits puts a
# delimiter, a space or tab, or a `- ` bullet before the key, and `statuses:`
# offers an `s`. The lookbehind was removed with it -- but that removal is
# measured, not proved. `(?<![\w-])` is unexercised by this corpus, not
# unreachable: the corpus reads 632 references with it and 632 without, so no
# line in the measured fleet reaches it. One shape would: the `\n` alternative
# ends on the literal `n`, a word character, so a source-string fixture writing
# that escape with no indentation after it -- `"on: push\nuses: Verjson/.github@
# <sha>"` -- matches under this pattern and does not under the lookbehind
# variant. The lookbehind goes because nothing in the fleet distinguishes the
# two and an assertion no test can kill is worse than none, not because it could
# not fail.
# The class admits the YAML flow indicators `{`, `[` and `,` for the same reason
# the ref alternative above closes on them: they are where a key begins rather
# than where a value ends. `{` opens a flow mapping and `,` separates its
# entries, so `steps: [{uses: A@<sha>}, {uses: B@<sha>}]` puts a `uses:` key
# after each of them; `[` opens a flow sequence whose entry may be a single pair
# with no braces at all -- `steps: [ uses: A@<sha> ]` -- which YAML parses to the
# same structure as the block form. Without them such a pin is dropped whole,
# muted by its position on the line rather than by anything about its content.
# No adopter in the measured fleet writes a step this way today, so this gains
# nothing now and costs nothing: the fleet sweep measures gained=[] lost=[].
USES_RE = re.compile(
    r"(?:^|[\"'`#{\[,]|\\n)[ \t]*(?:-[ \t]+)?"
    r"(?-i:(?:uses|\"uses\"|'uses'))\s*:\s*[\"']?Verjson/\.github"
    r"(?:/(?P<path>[^@\s\"']+))?@"
    r"(?P<ref>[0-9a-f]{40}(?![\w./+-])|(?:\$\{\{[^}\n]{0,200}\}\}|[^\s\"'`\\])+)",
    re.IGNORECASE)

SHA_RE = re.compile(r"^[0-9a-f]{40}$")
# GitHub resolves `owner/repo@ref` -- a reference with no path segment -- to a
# root action file, trying `action.yml` and then `action.yaml`. A pathless
# reference is reported with `path=None`, and a consumer that must name a file
# resolves it through this tuple rather than guessing one of the two.
ROOT_ACTION_PATHS = ("action.yml", "action.yaml")


def references(text: str):
    r"""Yield `(path, ref)` for every contract reference in `text`, per line.

    Per *line*, not over the whole text, and that is a behavioural choice rather
    than a detail. `\s*` after the key spans a newline, so a pattern run over
    un-split text lets a bare `uses:` on one line take the next line's hub
    reference as its value. In the YAML both sweeps read, a `uses:` key and its
    value are on one line; two lines that only look adjacent are not a
    reference. The line-bounded classes inside `USES_RE` then mean what they
    say, and the two sweeps cannot disagree about the extent of a match.

    That leaves one asymmetry, and it is deliberate rather than overlooked. A
    `uses:` key whose value is a plain scalar on the *next* line is legal YAML
    that Actions accepts. This yields nothing for it, so the inventory contributes
    no row, while `contract-version` still reports it through `USES_KEY_RE` as a
    key with "no path@ref this scan can read". The rationale survives the
    flow-style widening above unchanged, because that widening is about where a
    value ends *within* a line and this is about a value that is not on the line
    at all: admitting it here means letting `\s*` span a newline again, which is
    what let a bare `uses:` adopt an unrelated following line's reference. The
    residual is therefore real and bounded -- an adopter writing the split form
    is named by the per-repository sweep and is silently absent from the fleet
    row set, never reported as a repository with no such reference -- and it is
    named here rather than closed, because closing it needs a YAML parse rather
    than a wider pattern.
    """
    for line in text.splitlines():
        for match in USES_RE.finditer(line):
            yield match.group("path"), match.group("ref")


def pins(text: str):
    """Yield `(path, sha)` for every reference whose ref is a 40-hex commit.

    The inventory's narrowing, and the only difference between the two sweeps.
    It is a filter over `references()` so that widening what counts as a
    reference widens both sweeps at once -- which is the drift #1482 reports.
    """
    for path, ref in references(text):
        if SHA_RE.match(ref):
            yield path, ref
