# 0196 — The guard-liveness event stream declines what it cannot classify

- **Date:** 2026-09-18
- **Status:** Accepted
- **Related:** [ADR 0194](../0194-a-ref-scan-anchored-on-two-shapes-reads-green-over-the-shapes-it-cannot-see/README.md), [ADR 0192](../0192-encode-adopter-ref-names-before-they-reach-a-url/README.md)
- **Issues:** [#1464](https://github.com/Verjson/.github/issues/1464)
- **Pull request:** [#1469](https://github.com/Verjson/.github/pull/1469)

## Context

ADR 0194 widened `scripts/ci-gate/default-branch-uri-encoding.test.sh` from two recognized
ref shapes to the set it reads today. That gate is the security anchor for privileged merge
automation across the adopter fleet: an allowlist entry that cites a guard is only honest
while that guard is still *live*, and liveness is decided by a hand-rolled walker over bash
constructs — `branch_events` feeding `negated_branch_dominates`.

This ADR is not about a new counterexample. It is about the record of the ten that came
before it, because that record, not any single vector, is the evidence for the decision.

**Ten review rounds each closed a real fail-open in this walker, and each was followed by
another fail-open in the same area.** Every round ended with a written closure argument, and
every one of those arguments was falsified by the next round:

- Rounds 5 and 6 added constructs the walker could not see (`do`/`done`, `case`/`esac`,
  subshells, function definitions, backgrounded groups, run-off expansions).
- Round 6 inverted the *record* default: `arm_record_is_modelled` now enumerates what the
  record model represents and rejects everything else.
- Rounds 7, 8 and 9 each found the next fail-open *inside the mechanism the previous round
  had just added* — the `case`-label exception reading a label's first word as a command,
  then an ordinary nested `case "$b" in y)` being admitted as a label.
- Round 10 found that all five of those rounds had been layered on an asymmetry none of them
  saw: the stream read only a *part's first word*, and a closer is always first-word while an
  opener is not, so the stream was systematically **net-negative** in openers. It rewrote the
  scan to read every command-position word, and argued its restart set was "closed because it
  is read off that grammar rather than collected from counterexamples."

An independent review falsified that argument in one sitting. `coproc` was in the restart
set; `coproc`'s **optional NAME** was not. The scan read `coproc` (restart), read the name as
an ordinary command word, set `at_command=0`, and every later command-position word in that
part became invisible. `coproc c if q; then` emitted no events at all where the unnamed
`coproc if q; then` emitted `if` — and only the unnamed spelling was pinned.

Reproduced end to end before anything was changed, on bash 5.2.21, `bash -n` clean:

```
if ! [[ "$head_sha" =~ ^[0-9a-f]{40}$ ]]; then
  coproc c if q; then
    exit 1
  fi
fi
gh api "repos/$repository/commits/$head_sha"
```

read **LIVE** in both `whole` and `slice` mode; deleting just the two characters `c ` made it
correctly **DEAD**. Executed, it prints `REACHED use with [not-a-sha]` and the parent shell
exits 0 — the `exit 1` runs in the coprocess. It cleared every existing filter: no unpaired
parenthesis, no bare `&`, no unbalanced brace, no here-document, so
`arm_record_is_modelled` accepted the record and the walk scanned straight past it.

A second, related finding pointed the same way. The walker *stripped* grouping punctuation to
"judge the word", which manufactured command-position words out of arithmetic:
`if (( fi > 0 )); then a; fi` read `if fi fi`, a **spurious closer** that fires the guarded
return one level too shallow. Nothing in the stream caught it; only the record-level
parenthesis filter did.

### The generator, not the tokens

The common cause of all ten rounds is not any token. It is that `branch_events` was a
**permissive** stream: a command-position construct it had no rule for was scanned past in
silence, so an unmodelled construct and an absent one produced the same empty stream — and
"absent" reads as safe. Every round patched one token and left the generator running.

Patching `coproc NAME` would have been the eleventh such patch.

## Decision

**Push the inversion the repository already applies to records down into the event stream.**

`branch_events` no longer has a permissive default. A word in command position is exactly one
of three things, and the classification is **total over bash's reserved words**:

1. a reserved word the walk positively classifies — restart, open a `case` pattern, or stop;
2. a reserved word it does **not** classify — emitted as `decline:<word>`;
3. anything else, which by bash's grammar **is** the command name, after which the rest of
   the part is its arguments and command position genuinely ends.

The reserved words are a closed set bash itself publishes as `compgen -k`.
`branch_events_classifies_every_reserved_word` asserts that the four buckets partition that
set exactly — disjoint, total, and inventing nothing. A word bash adds, or one an edit drops
from a bucket, therefore reddens that assertion instead of silently rejoining a permissive
default. This replaces a prose closure argument with a checkable one, which is the specific
thing ten rounds of prose kept getting wrong.

`negated_branch_dominates` reads a `decline:` **before** any event the same record also
emitted, so a record that both closes a construct and carries an unclassified word cannot
return through its `fi` first.

Two consequences fall out rather than being special-cased:

- **`coproc` is declined, not modelled.** Modelling `coproc [NAME] command` is one more token
  rule of exactly the kind that produced ten rounds of holes. Declining it cannot be wrong in
  the fail-open direction.
- **Doubled `((` / `))` is declined.** Counting the grouping punctuation instead of stripping
  it kills the arithmetic spurious-closer class without any rule naming `fi`, `done` or
  `esac`. That it falls out is the test that the inversion did the work.

This is an allow-list shaped fail-closed default. It is deliberately *not* a deny-list of
known-bad tokens: a deny-list is unwinnable here, and building one inside the inversion would
reintroduce the generator this ADR exists to remove.

## Consequences

**The measured cost is zero, and the measurement is now asserted rather than recorded.**
Across the scanned corpus — 144 files, 33,196 logical records — 132 records now carry a
decline, and **all 132 were already refused** by `arm_record_is_modelled`'s parenthesis rule.
They are embedded `jq` and `awk` program bodies that `logical_lines` reads as records. The
corpus contains no `coproc` at all.

Consequently **no site needed a new allowlist entry and none of the published counts moved**:
77 recognized ref sites, 21 of them Python, 144 files, 18 jq encoders, 7 Python encoders,
14 allowlisted sites, 11 allowlist entries — all unchanged.

`stream_only_declines` pins that zero: it counts records the stream declines that
`arm_record_is_modelled` would otherwise have accepted, which is the only decline that costs
the anchor real reach. A later widening that does cost reach reddens there instead of passing
quietly, and the message says explicitly not to raise the number to go green. A companion
floor requires at least one declining record in the corpus, so the zero cannot be vacuous.

**What was deleted rather than narrowed.** The pinned assertion that `coproc` is a *restart*
— that the `if` after an unnamed `coproc` is counted — is gone, and what it proved is gone
with it: the walk no longer counts openers inside a `coproc`'s command at all. That loss is
one-directional. A `coproc` record now rejects the walk instead of being modelled, so it
costs reach, never safety. Both spellings are pinned now, because pinning only the unnamed
one is what let round 10's closure argument stand.

**Runtime.** The corpus cost measurement adds two passes over the scanned records. A sound
prefilter derived from the decline bucket itself — not a hand list — keeps the suite at
roughly 1m39s against a 1m16s baseline on the development host.

### What this does NOT buy

State this plainly, because ten rounds of this file's history are rounds in which someone
claimed more than they had:

- **It is not a proof of correctness against bash's parser.** The walk is still a
  command-level approximation over structurally-blanked text. It does not parse bash and this
  change does not move it closer to doing so.
- **It does not prove each reserved word is in the right bucket.** `compgen -k` totality
  proves only that none is *missing*. A word classified as `stop` that should restart is
  still a hole, and only the individual pinned cases speak to that.
- **It does not close the classes ADR 0194 and this file's header already enumerate** — a
  guard moved into dead code, a vacuous guard, a redefined terminating word, the `whole`-mode
  end-of-file residual, the positional-not-dataflow limit, or a pinned literal matched inside
  a string.
- **It is not a claim that the eleventh round is the last one.** It is a claim about the
  *failure mode* of the next one: an unmodelled construct now surfaces as a visible,
  allowlist-shaped decline instead of a silent fail-open. That is the property being bought,
  and it is the only one.

ADR 0194 is the direct predecessor and is not reversed by this: it decided what the scan
recognizes, and this decides what the liveness walker does with what it cannot classify.
