# 0046 — Baseline repository hygiene: a root README that answers three questions

- **Date:** 2026-08-02
- **Issue:** [Verjson/.github#232](https://github.com/Verjson/.github/issues/232)
- **Prompted by:** [Verjson/renovate-config#5](https://github.com/Verjson/renovate-config/issues/5)
  — a repository that shipped with neither a README nor repository-specific CI
- **Category:** organization CI policy (org-required workflow surface)

## Context

New repositories are created faster than anyone documents them. `renovate-config`
reached production use with no README at all: a reader who found it could not tell
what it was for, who to ask, or how to check a change locally. The failure mode is
not a missing file — it is that nothing in the organization ever said the file was
required, so no repository was ever wrong to omit it.

Two shapes were available. Copy a hygiene job into every repository, which drifts
the moment the policy changes and can only be fixed N times. Or centralise one
check here and have repositories call it. The organization already centralises the
merge gate, the reusable CI workflows, and the changelog contract for exactly this
reason, so the second shape is the house pattern.

Three constraints shaped the rest:

1. A check that only reads a diff cannot see a **deletion**. A PR removing the
   README adds no line, so a diff-based rule reports it as touching nothing.
2. A check strict about wording becomes a check people route around. A rule that
   demands house headings would fail most existing compliant READMEs on day one.
3. An exemption the audited repository grants itself is not an exemption. It is a
   bypass with paperwork.

## Decision

### 1. Scope of this decision

This ADR decides the **central mechanism**: the check, its rule, its exemption
register, the seeded template, and the audit-first default. Turning enforcement on
for any specific repository, and the order of the rollout across the existing
estate, is a separate human decision and is **not** decided here.

### 2. The check reads the resulting tree, never the diff

`scripts/repo-hygiene.sh` resolves the root README from the git **tree** at the ref
under test — on a pull request, the merge result. A PR that deletes the README
therefore produces a tree with no README and is a finding, which a diff-based check
cannot see (constraint 1).

The README is matched the way GitHub picks one to render: a root blob named
`readme`, `readme.md` or `readme.markdown` in any case. Insisting on the exact
spelling `README.md` would report a finding the author cannot reproduce, because
their `readme.md` renders perfectly on the repository's front page.

Subdirectory READMEs do not count. `docs/README.md` is documentation; the policy is
about where a reader lands.

### 3. The substance rule, stated exactly

A compliant README satisfies **all** of:

- it exists at the repository root in the resulting tree, and
- it contains at least one non-whitespace character, and
- for each of the three required topics — **purpose**, **ownership/contact**,
  **local validation/operation** — it carries a Markdown heading (`#` to `######`,
  any case, optional trailing colon) whose text starts with one of that topic's
  documented aliases, and
- under each such heading, before the next heading of any level, it carries at
  least **40 non-whitespace characters** of prose that is not purely a placeholder
  token (`TODO`, `TBD`, `N/A`, `none`, `coming soon`, `...`, `XXX`).

The alias lists, which are the policy and live in one place in the script:

| Topic | Heading aliases |
| --- | --- |
| purpose | purpose, overview, what is / what it is / what this is / what it does / what this does, about, introduction |
| ownership | owner(s), ownership, maintainer(s), contact(s), support, team |
| validation | local validation / development / dev / setup / check(s), developing locally, development locally, running locally, run locally, validation, validating, usage, getting started, build and test, testing, test(s), operation(s), running it, running the tests |

**Why this rule and not a stricter one.** The check answers "was the question
answered?", never "is the answer good". Judging quality is review's job, and a
hygiene job that tried would be both wrong often and easy to game. Forty characters
is roughly one real sentence: high enough that `TODO`, a bare link, or a repeated
title do not pass; low enough that a genuinely small repository can comply honestly
in three sentences. Alias matching rather than fixed headings means an existing
README that already answers the questions passes without being rewritten to a house
style (constraint 2).

**Known limits, stated rather than implied.** Setext headings (`Purpose` underlined
with `=====`) are not recognised. Prose that answers a question without a heading
does not satisfy it. Aliases are English-only. All three are accepted false
positives: the remedy — adding a heading — is cheap and makes the README better,
whereas prose inference would make the verdict unpredictable.

### 4. Exemptions are granted centrally, in a tracked, expiring register

Four classes may be exempt: **archived**, **mirror** (vendor snapshot),
**generated** (published artefacts only), **bootstrap** (an intentionally empty
reserved repository).

The exemption register is `docs/repo-hygiene/exemptions.tsv` **in this repository**.
Each row is `repository`, `class`, `review-by` (a date), `reason`. Auditability
comes from four properties, each enforced by the script rather than by convention:

- **The grant lives in the central repository.** The reusable workflow checks out
  `Verjson/.github` at a caller-pinned ref and runs *that* copy of the script
  against the consumer's tree. The register is resolved next to the script, so
  nothing in the repository under audit can supply, edit, or shadow it. Adding a row
  is a reviewed pull request here.
- **No self-assertion.** There is no in-tree marker file, label, or workflow input
  that exempts a repository. A repository committing `.repo-hygiene-exempt` is still
  checked; that path is covered by a test.
- **Every grant is attributable and expiring.** A row missing a reason or a
  review-by date is rejected. Past its review-by date the row stops exempting and
  the repository re-enters the backlog, so a grant nobody re-reads decays instead of
  becoming permanent. `archived` rows are renewed like any other; an archived
  repository that came back to life is exactly the case worth re-examining.
- **An unrecognised class is a fault, not a narrower grant.** A row claiming a class
  outside the four fails the check closed rather than being ignored, so a typo can
  never quietly widen or silently void the register.

### 4a. An exemption is only granted by a ref that was reviewed and merged

The register living in the central repository is necessary but not sufficient.
`actions/checkout` accepts `refs/pull/<n>/head`, and `Verjson/.github` is public,
so anyone able to open a pull request here can create a ref carrying a register
row that exempts their own repository — no merge, no review. A consumer pinning
that ref would be self-exempting through the central register, which is precisely
what this section says an exemption is not; the same ref also supplies the script
that does the auditing.

The caller must supply a full lowercase 40-character SHA; branches and tags are
mutable and could silently select different policy code on a later run. That
shape check runs before any checkout. It is necessary but not sufficient: a
commit on an unmerged PR branch is a SHA too. The workflow therefore also
resolves the checked-out policy commit and requires `compare/main...<sha>` to
report `identical` or `behind`, which proves reachability from the default branch
and therefore "reviewed and merged". An unreadable comparison is a fault, never a
pass. Both boundaries are enforced by extraction-based behavioral tests added
with [#351](https://github.com/Verjson/.github/issues/351).

### 3a. Sections are read with markdown block context

The substance rule is heading-driven, and a line-oriented reading of headings is
not sound: a README whose entire body sits inside an `<!-- -->` comment, or whose
"headings" are shell comments inside a fenced code block, renders as nothing at
all and would still have answered all three questions. Both were demonstrated
bypasses. The parser therefore tracks fence and comment state and ignores
headings inside either.

For the same reason a heading only ends the section it opened when it is at the
**same level or shallower**. `### Goals` under `## Purpose` is part of the purpose
answer; treating any heading as a terminator reported every sub-sectioned README
as non-compliant, which would have buried the real backlog in false findings.

### 4b. review-by is a date, and today must be knowable

`review-by` is compared lexicographically, so a row is only expiring if the value
is really a date. `never` and `9999-99-99` both parse as "later than today"
forever and would silently convert an expiring grant into a permanent one, so the
column is validated by round-tripping through `date` and anything else is a fault.
The same applies to the current date: an empty `today` makes every lapse test
false, so nothing would ever expire — the one invariant this register exists to
keep. An undeterminable today is a fault, not a quiet pass.

### 5. Audit is the default; a fault is not a verdict

`mode` defaults to `audit`: findings are printed and the job stays green, so
adopting the check cannot turn any repository's CI red on day one. `mode: enforce`
is a deliberate per-caller flip once that repository's backlog is clear.

Mode governs **policy findings only**. A *fault* — an unreadable tree, an
unreadable or malformed register, an unknown mode — exits non-zero in **both**
modes. A hygiene check that reports success when it could not run is a check that
silently stops working, and the organization has already shipped that class of bug
three times. Exit codes are distinct so a rollout dashboard can tell them apart:
`1` is a policy finding, `2` is a fault.

### 6. Hygiene is baseline CI, never evidence that behaviour works

A green hygiene check means a reader can orient themselves in the repository. It
says nothing about whether the repository's code works. It never substitutes for
repository-specific build, test, or config validation, and a repository whose only
CI is this check has no CI. This is stated in the workflow header, in the merge-gate
section of `README.md`, and here, because the failure mode is a repository that
looks covered.

### 7. New repositories are seeded, not corrected

`docs/repo-hygiene/README.template.md` is a README that passes this check, and a
test asserts it does — a template that failed the policy it seeds would teach every
new repository to start non-compliant. Organization template repositories copy it.

## Consequences

- One rule, one script, one register; changing the policy is one reviewed PR here
  rather than N repository edits.
- Landing this changes nothing for any existing repository until that repository
  adds the caller. Audit mode means even then the first outcome is a report.
- The alias list will need occasional widening. Widening it is a PR against this ADR
  and the script together — the table above is the policy, and the script is its
  only implementation.
- Exemptions accumulate review work by design: every row expires. That is the cost
  of not having permanent invisible exceptions.

## Rollback

Remove the caller from a repository, or set `mode: audit`, to stop enforcement
without touching the central mechanism. Deleting `.github/workflows/repo-hygiene.yml`
removes the mechanism entirely; nothing else depends on it.
