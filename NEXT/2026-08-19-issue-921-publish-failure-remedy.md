---
date: 2026-08-19
issue: 921
title: Name the safe remedy when node-release.yml's publish step fails
---

`node-release.yml`'s restart-safe publish step could not distinguish a genuine `npm publish` failure (the version never reached the registry) from the registry-mismatch/spoof cases it also guards against, so both surfaced the same "cannot read the allegedly existing registry version" error. That message reads as a wedged release when the actual state is expected-recoverable — the changelog contract's verify-then-snapshot-then-publish ordering (ADR 0069) means the git tag and immutable `CHANGELOG/<version>.md` already exist by the time this step runs, and re-dispatching the same version safely resumes publication alone. Two adopters hit this in one day from unrelated causes (an organization billing limit, a transient `429` fetching `actions/checkout`), and the ambiguous message caused a real downstream misdiagnosis. The error now states the remedy directly: the tag and snapshot are safe, this is not a wedged release, and re-dispatching the same version resumes publication automatically.
