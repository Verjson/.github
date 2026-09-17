---
date: 2026-09-17
issue: 1382
impact: patch
title: The generated ADR index no longer fights prettier
---

`scripts/gen-adr-index.sh` now emits a `<!-- prettier-ignore -->` guard and a
trailing blank line inside the region it already owns, so `prettier --check` and
`gen-adr-index.sh --check` agree by construction instead of being mutually
unsatisfiable over `docs/decisions/README.md`.

An adopter whose canonical `ci` lane runs prettier could previously satisfy one
check or the other, never both: the generator emitted the table unpadded, and
prettier padded every cell to its column width. Each adopter discovered this the
first time it regenerated the index, by going red, and fixed it locally with a
`.prettierignore` entry that a later regeneration could drop (#1382).

Emitting the padded table instead — the fix the issue proposed — would not have
settled it. Padding is what prettier produces only under the default
`proseWrap`; a `proseWrap: never` adopter gets a third, compact shape, and
`printWidth` selects between them. It would also have coupled a pure bash and
awk generator to prettier's internal string-width algorithm across every future
prettier release, and rewritten all 185 rows of every adopter's index. The
guard comment removes the conflict at its root rather than tracking it: prettier
leaves the block byte-identical under every `proseWrap` and `printWidth` setting
tested, no adopter has to carry an ignore entry, and a repository that does not
use prettier carries an inert HTML comment. The diff to an existing index is two
added lines.

Verified against prettier 3.9.7 on an adopter-shaped tree: before the change,
`--check` failed after `prettier --write` under both `preserve` and `never`;
after it, prettier leaves the file unchanged and `--check` passes under
`preserve`, `never` and `always`. `scripts/ci-gate/gen-adr-index.test.sh` pins
the emitted shape unconditionally and runs the real formatter wherever one is
installed; deleting either the guard or the blank line fails both assertions.
