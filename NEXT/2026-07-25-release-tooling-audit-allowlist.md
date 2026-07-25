# Release-tooling audit gains a dated, fail-closed advisory allowlist — 2026-07-25

Unwedges org-wide CI (#146). A newly-published advisory —
[GHSA-mh99-v99m-4gvg](https://github.com/advisories/GHSA-mh99-v99m-4gvg),
`brace-expansion <=5.0.7`, high — turned every PR in the repo red on
`actions-ci`'s `npm audit --audit-level=high` step, with no code change: the
vulnerable copy is **bundled** inside npm's own CLI
(`semantic-release` → `@semantic-release/npm` → `npm`), so `npm audit fix`,
a `semantic-release` bump (already latest) and `overrides` all fail to move it,
and npm has shipped no release carrying the fixed `brace-expansion@5.0.8`.

The bare invocation is replaced by `scripts/release-tooling-audit.sh`, which
parses `npm audit --json` and blocks on any high/critical advisory that is not
named in `.github/release-tooling/audit-allowlist.json`. Each allowlist entry
carries a GHSA id, a reason and a `review-by` date; an entry that outlives its
`review-by`, or that stops matching a reported advisory, **fails the gate** — so an
accepted risk cannot become permanent and a resolved exception cannot linger as
dead permission. Every unparseable path (bad/absent JSON, wrong report shape, an
uninterpretable npm exit, high counts with no extractable advisory, a malformed or
missing allowlist) exits non-zero: an unreadable audit never reads as clean.

Seeded with exactly one entry, GHSA-mh99-v99m-4gvg, expiring **2026-08-25**.
20 unit tests in `scripts/release-tooling-audit.test.sh` drive the script against
stubbed `npm audit --json` output (no network) and are wired into `actions-ci.yml`.
See [ADR 0025](../docs/decisions/0025-release-tooling-audit-allowlist/README.md).
