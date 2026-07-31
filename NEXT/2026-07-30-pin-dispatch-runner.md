# Bootstrap a verified GitHub CLI for trusted dispatch — 2026-07-30

The metadata-only merge dispatcher now installs a pinned, checksum-verified
GitHub CLI when a selected isolated runner does not already provide `gh`,
preventing heterogeneous self-hosted hosts from failing after a green build and
review gate. Existing runner policy, trusted identity checks, and credential
boundaries remain unchanged
([#257](https://github.com/Verjson/.github/issues/257), ADR 0037).
