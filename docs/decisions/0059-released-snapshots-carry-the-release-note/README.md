# 0059 — Released snapshots carry the release note; the running log keeps the argument

- **Date:** 2026-08-05
- **Issue:** Verjson/.github#426
- **Category:** Changelog contract
- **Status:** Accepted

## Context

ADR 0038 gave the changelog one fragment format and one renderer. Two callers
consume it, and their needs are opposite:

- `render-next` produces the **running log** — the engineering diary, where the
  org convention explicitly asks an entry to carry its rationale, because that
  is the record a future maintainer reads before changing the same thing again;
- `release` produces `CHANGELOG/<version>.md` — **release notes**, read by
  people who want to know what changed.

Nothing constrained body length (`load_canonical` requires only a non-empty
body), so the diary shipped as the release notes.

`Verjson/verjson-ai` was the first repository to cut a release under this
contract, and `CHANGELOG/v0.11.0.md` came out at 174 KB / 2417 lines for 62
entries, with `CHANGELOG.md` at 199 KB. This repository's own unreleased
fragments run 58-84 lines, so it is not one repository writing badly — it is one
renderer serving two audiences and the diary winning by default.

## Decision

**A released snapshot renders `title` plus the lead paragraph. `render-next`
keeps the whole body.**

The lead is everything up to the first blank line: a plain split, with **no
block-type detection**. That is deliberate and load-bearing. A first pass that
tried to recognise non-prose openers — so that a fragment starting with a list
or a heading could be handled specially — produced 7 false positives across the
62 entries, every one of them ordinary prose beginning `#79 threaded ...`, which
is not an ATX heading in CommonMark but is the obvious way to write that bug.
A rule that is wrong is worse than one that is coarse, because the output is
immutable the moment it is released.

An optional `summary:` overrides the lead **for the released form only**. It is
an escape hatch, not a requirement: across those 62 entries the lead is
1/6/10/12 lines (min/median/p90/max), none is empty, and all 62 are prose, so no
existing fragment needs editing for this to work. `summary:` is validated
exactly as `title:` is — non-empty, and ambiguous quoting rejected at PR time
(#425) — because both reach a file that can never be corrected.

`render-next --as-released` renders the released shape from unreleased
fragments, and `generated-artifacts.yml` prints it into the check's job summary.
Once the two forms diverge, the released one is otherwise invisible until it is
permanent; this makes it visible while the fragments are still editable.

### This fix is forward-only, and that is the decision

`render_released` rebuilds `CHANGELOG.md` from the snapshots on **every**
release, so verjson-ai's 174 KB v0.11.0 section is permanent no matter what
`render()` does next. The fragments are recoverable from git history, so a
re-render migration is *possible*.

**It will not be done, and the reason is not effort.** Doing it establishes that
a released snapshot is editable when the reason is good enough, which is the
exact guarantee this contract exists to provide. Being first should cost
verjson-ai one fat section; it should not cost everyone the immutability
property. The same wall stopped a cosmetic heading rename earlier the same day,
and it should have.

This is recorded here because the next person to notice the 174 KB section will
propose the re-render again, reasonably, and the answer needs to be a decision
they can read rather than an argument they have to lose.

A correction to released content is made the way every other correction is: a
later release, with a fragment that says what was wrong.

## Consequences

Fragment authors now write the **lead paragraph as the release note**, with the
argument beneath it. `NEXT/README.md` says so, and `--as-released` shows the
result. The failure mode this introduces is a lead that reads as internal
narrative — visible in the job summary before merge, and fixable with
`summary:`.

`summary` joins the known metadata keys. Under #424 an unknown key warns rather
than fails, so a fragment carrying `summary:` stays readable by a repository
pinned to an older contract — it renders the lead instead of the override,
rather than failing validation. Without that relaxation this ADR would have been
a fleet-wide flag day.

Consumers pick this up by bumping their pinned `contract_ref`. Repositories that
have already released keep their existing snapshots verbatim, per the decision
above; only their next release is affected.

ADR 0038 is refined, not superseded: fragment format, identity, immutability of
snapshots, and the `NEXT/` → `CHANGELOG/<version>.md` flow are unchanged. What
changes is what `release` writes into the snapshot.
