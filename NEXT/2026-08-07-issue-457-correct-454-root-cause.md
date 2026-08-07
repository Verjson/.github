---
date: 2026-08-07
title: Correct the stated root cause of the folded-scalar front-matter failure
issue: 457
---

The `#454` entry in `CLAUDE.md` said `parse_frontmatter` "rejects a key with an empty value".
Traced against `scripts/changelog.py:90-97`, that is not what happens, and the difference sends
a reader to the wrong branch:

```python
key, separator, value = line.partition(":")
if not separator or not key.strip() or not value.strip():
    raise ChangelogError(f"{path}: invalid metadata line: {line!r}")
```

For `summary: >-`, `value.strip()` is `">-"` — non-empty, so the empty-value check **passes**.
The failure comes from the folded scalar's **continuation** line, which has no `:` and trips
`not separator`.

And the case with no continuation line is worse than an error: `>-` is accepted as a value and
stored as the literal string `">-"`, silently, so a release note reads as two punctuation
characters rather than failing loudly.

The workaround is unchanged — keep `summary:` on one line — and #454 remains open for the real
fix. Only the diagnosis is corrected.

Found by the gate's own non-blocking follow-up filing (#457) on merged PR #456, which is the
mechanism working: the review caught an imprecise causal claim in prose that no test covers.
