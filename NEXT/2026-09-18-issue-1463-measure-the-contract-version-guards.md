---
date: 2026-09-18
issue: 1463
title: Measure the contract-version guards instead of describing them
impact: patch
---

`scripts/contract-version.py` carried three claims its suite did not measure, and
one of them was the headline of the change that introduced it.

The symlink guard is the one that mattered. The test that was supposed to prove
`node_modules` is no longer a hole builds a real **directory** and vendors a
skewed caller inside it — which passes whether or not the guard exists, because a
tracked directory is never an index entry in the first place. The shape the guard
was written for is a `node_modules` **symlink** to a directory, which is exactly
what this repository's own 48c9cd36 ignores. There is now a test for that shape,
and deleting `if path.is_symlink()` reddens it: the scan follows the link, `stat`
succeeds on the target directory, `open` raises `IsADirectoryError`, and a
vendored tree becomes an `UNSCANNED` gap no adopter can clear.

Every guard named in #1463 is now checked by deleting it and requiring the suite
to redden, with the assertion that fires recorded rather than assumed:

| Guard | Mutation | Assertion that fires |
| --- | --- | --- |
| `if path.is_symlink()` in `_scan_files` | delete the branch | `node_modules` symlink test: `UNSCANNED ... (Is a directory)` against `[]`, plus the existing `link.yml` test's `PIN_MISMATCH` |
| `(?![0-9a-f])` in `HEADER_RE` | delete the lookahead | 64-hex digest test: `PIN_MISMATCH` naming the digest's first 40 characters |
| `isinstance(payload, list)` in `load_releases` | `if False:` | non-array document test: the `ValueError` says "every release entry must be an object", not "JSON array" |
| `isinstance(entry, dict)` in `load_releases` | `if False:` | non-object entry test: `AttributeError: 'str' object has no attribute 'get'` in place of the typed refusal |

The `HEADER_RE` rationale was false as written. It claimed a 64-hex container
digest sits next to a generated hub header, and none does: no line in this
repository matches both `Verjson/.github` and a 64-hex run. The boundary is kept,
because the header pass reads every comment line and so admits that shape — but
the comment, the covering test, and ADR 0191's verification section now say the
line is constructed rather than sampled. ADR 0191 also claimed an assertion about
a 40-hex string inside `.git` that the suite does not make and does not need:
git's object storage is never in the index, so the boundary excludes it by
construction rather than by a guard a mutation could delete.

Two host-dependence nits raised alongside these were already closed before this
change and are re-confirmed rather than re-fixed: the unreadable-file fixture is a
directory rather than `chmod 0o000`, which denies nothing to root in the container
CI runs in, and the `today_utc` test brackets the observed value between two
clock reads so a midnight-UTC rollover is not a flake.
