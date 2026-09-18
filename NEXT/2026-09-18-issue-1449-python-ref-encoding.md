---
date: 2026-09-18
issue: 1449
title: The ref-interpolation invariant reaches Python callers too
impact: patch
---

The enumeration in `scripts/ci-gate/default-branch-uri-encoding.test.sh` held every
`?ref=$…` and `git/ref[s]/heads/$…` interpolation in workflows and shell scripts to a
percent-encoding or a 40-hex constraint, but it never looked at `*.py`. Hub-privileged
Python built the same URLs outside it, so a new unencoded read there would have landed
silently — the hole ADR 0192's invariant exists to close, left open in another language.

The scan now covers tracked non-test `scripts/*.py` as well, in both syntaxes a Python
file uses: its own `{expression}` interpolations, and the shell it generates for adopter
workflows. Each Python encoder call is *evaluated* against the same hostile and
path-shaped fixtures the jq programs face, rather than matched by spelling, so the
positional rule is enforced by what the call produces: `urllib.parse.quote` defaults to
`safe="/"`, which keeps `/` literal for a query value, and only `safe=""` encodes it as
`%2F` for a path segment. A planted unquoted interpolation in a `.py` file reddens the
suite; so does flipping a correct encoder to the other position's form.

Bringing the newly covered callers into compliance:

- `scripts/ai-review-required-workflow-audit.py` percent-encodes the ruleset-supplied
  required-workflow ref before it reaches the contents query string.
- `scripts/renovate-changelog.py` encodes its two `?ref=` values as query values
  (`safe="/"`) instead of over-encoding `/` as `%2F`.
- `scripts/authn-type-surface-ruleset.py`, `scripts/cli-projects-package-surface-ruleset.py`
  and `scripts/dependency-supersession.py` restate the 40-hex constraint in the function
  that builds the URL, so a caller's guard is no longer what vouches for the read.
- The generated node required-workflow contract now asserts that the emitted admission
  step keeps its `^[0-9a-f]{40}$` guard on the SHA it reads at.

All of these were already safe in practice; none changes an emitted URL for the values
they receive today. The change is that the invariant, not a reader, is what says so.
