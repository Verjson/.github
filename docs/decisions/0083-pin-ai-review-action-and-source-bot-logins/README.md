# 0083 — Pin the AI review action and name source bot logins

- **Date:** 2026-08-09
- **Issue:** [#649](https://github.com/Verjson/.github/issues/649)
- **Category:** CI merge gate / third-party execution and bot authorization (sensitive-class)

## Context

The merge gate executed `anthropics/claude-code-action@v1`. That mutable tag
controlled code running with the workflow token and model credentials. The gate
also admitted `github-actions` because the action currently lowercases bot
logins and removes one trailing `[bot]` before comparing them. Neither property
was bound to a repository revision.

The audited `v1` tag resolved on 2026-08-09 to commit
`6b082c41935b4c8a3b8b0ef85ba4ba4d9eeb8975`. Its actor validation normalizes
both the actor and allowlist entries with lowercase conversion followed by
`replace(/\[bot\]$/, "")`.

## Decision

Every Claude review invocation uses that full immutable commit SHA, and the
authorization contract rejects mutable refs, non-identical pins, and pins other
than the audited revision. The configured allowlist records the exact GitHub
source logins `renovate[bot]`, `mend[bot]`, and `github-actions[bot]`; it does not
encode the action's normalized aliases and never admits a wildcard.

The organization Renovate policy's standard GitHub Actions manager detects the
immutable reference without a repository-local override. Any proposed pin must
pass the authorization mutation tests, making the source audit and any
normalization change visible in the same PR.

## Consequences

- Moving the upstream `v1` tag cannot change code executed by the merge gate.
- An update is intentional and reviewable rather than silently inherited.
- The exact bot identities remain understandable without knowing the action's
  internal representation, while the immutable revision binds its comparison
  behavior.
- A future action revision that changes normalization requires updating this
  ADR and its focused security contract before adoption.
