---
date: 2026-08-02
issue: 232
title: Baseline repository-hygiene check for a root README, audit-only by default
---

Added one central repository-hygiene check instead of a job copied into every
repository: `scripts/repo-hygiene.sh` plus the reusable workflow
`.github/workflows/repo-hygiene.yml`. It requires the repository's root
`README.md` to answer purpose, ownership/contact, and local validation, with the
exact rule and its known limits recorded in
[ADR 0045](docs/decisions/0045-baseline-repository-hygiene/README.md).

The check reads the git **tree** the merge would produce, not the diff, so a pull
request that deletes the README is a finding — a diff-based rule sees no added
line and reports nothing. Substance is alias-matched headings plus at least one
real sentence under each, so an existing README that already answers the questions
passes without being rewritten to a house style.

Exemptions (archived, mirror, generated, bootstrap) are granted only in
`docs/repo-hygiene/exemptions.tsv` here, are attributable, and expire on a
review-by date. A repository cannot exempt itself: the workflow runs the central
copy of the script and register against the consumer's tree.

It ships in **audit** mode by default — findings are reported and the job stays
green — so adopting it cannot turn a consumer's CI red. Enforcement per repository
and the rollout across the existing estate are deliberately **not** part of this
change. Faults are exempt from that softening: an unreadable tree, an unreadable or
malformed register, or an unknown mode exit non-zero in both modes, because a check
that passes when it could not run is one that silently stops working.

Also seeded `docs/repo-hygiene/README.template.md` (a README that passes the check,
asserted by a test), brought this repository's own README into compliance, and
recorded in the merge-gate section of `README.md` that hygiene is baseline CI and
never evidence that domain behaviour works.
