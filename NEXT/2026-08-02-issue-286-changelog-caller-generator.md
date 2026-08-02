---
date: 2026-08-02
issue: 286
title: Generate the consumer changelog caller instead of hand-writing it
---

Consumers need two files that must pin the same contract commit — a
`changelog-validate.yml` caller and a `render-next.sh` that fetches
`changelog.py` at that commit — and the contract described neither. The first
three adopters each hand-wrote them and each produced a slightly different
shape, which is the drift the contract exists to remove, reappearing in the act
of adopting it.

`scripts/gen-changelog-caller.sh` now emits both, mirroring
`gen-privileged-merge-caller.sh` (ADR 0042). The ref is validated as a bare
40-hex commit rather than quoted and interpolated: both outputs embed it, one
into YAML and one into a shell assignment, and the sibling generator has a
recorded instance of YAML injected through exactly such a parameter.

`docs/changelog/README.md` gains a Consumer adoption section covering the
generator, why rendering is fetched rather than vendored, and the requirement
that adopters test their two pins for agreement — divergence is silent, since
both files keep working while local output stops predicting CI.

Tracks [#286](https://github.com/Verjson/.github/issues/286).

The generator self-validates before emitting — YAML through `yaml.safe_load`,
the renderer through `bash -n` — matching the sibling, so a broken emission
fails at the developer's terminal rather than in a consumer's CI. The generated
renderer downloads through `mktemp` rather than a fixed `.tmp` name, since
concurrent renders share one cache directory, and its fetch-failure branch is
covered with a stubbed `curl`: non-zero exit, a diagnostic, and no partial file
left where the next run would exec it as the contract.
