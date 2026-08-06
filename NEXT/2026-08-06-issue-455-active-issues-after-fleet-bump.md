---
date: 2026-08-06
issue: 455
title: 'docs(claude): record three defects the fleet pin bump exposed'
---

Working notes now carry the three org-level defects that surfaced while moving
the fleet to contract pin `f12dca7`.

#455 is the one that blocks work: `gen-changelog-caller.sh` emits a contract
test that rejects `.releaserc.json`, while canonical `node-release.yml` is still
semantic-release and still requires it. An npm-publishing adopter cannot satisfy
both, so `verjson-cli` landed the generated test unwired rather than delete its
only publish path. Every npm adopter will rediscover this mid-bump until the
release path is decided.

#441 gained a second instance in a different repo and a second terminal error
subtype, so the note tells the next session to re-run a suspicious verdict
instead of dismissing it — the placeholder displaced a review that went on to
find a real defect.

#454 records that `summary:` rejects the folded scalar an author reaches for,
which cost every repo in the bump a round of one-line rewrites.
