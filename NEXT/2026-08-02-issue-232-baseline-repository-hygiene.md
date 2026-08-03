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
[ADR 0046](docs/decisions/0046-baseline-repository-hygiene/README.md).

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

An adversarial review before merge closed two bypasses and four wrong verdicts.
`hygiene_ref` was a free string handed to `actions/checkout`, which accepts
`refs/pull/<n>/head`; because this repository is public, anyone could have opened
a pull request adding a row exempting their own repository and pinned that ref
without it ever being merged. A SHA shape check does not close it — a PR-branch
commit is a SHA — so the workflow now requires the resolved policy commit to be
reachable from `main`. Separately, the heading reader had no markdown block
context, so a README whose whole body sat inside an HTML comment, or whose
headings were shell comments in a fenced block, rendered as nothing and passed.

The same pass fixed four verdicts that were simply wrong: a subheading ended its
parent section (so every sub-sectioned README was a false finding), a CRLF README
failed all three topics, a trailing `--mode` spun forever instead of faulting, and
an unparseable `review-by` — or an undeterminable current date — turned an
expiring exemption into a permanent one. A final register row without a trailing
newline was silently dropped, taking its class and review-by validation with it,
which is the default path for every newly appended grant. Fault-vs-finding exit
codes are now asserted exactly rather than as "non-zero": making `die` exit 1
previously broke no test and now breaks eleven.

Also seeded `docs/repo-hygiene/README.template.md` (a README that passes the check,
asserted by a test), brought this repository's own README into compliance, and
recorded in the merge-gate section of `README.md` that hygiene is baseline CI and
never evidence that domain behaviour works.
