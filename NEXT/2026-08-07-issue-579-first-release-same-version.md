---
date: 2026-08-07
issue: 579
title: Allow the scaffold version on a package's first release
summary: Generated Node release callers now accept a dispatch whose version already matches the scaffold manifest.
---

Add npm's `--allow-same-version` guard to the generated pre-release manifest stamp. This keeps
the no-lifecycle-scripts verification boundary while allowing a newly scaffolded `0.1.0`
package to publish its first `v0.1.0` release.

The generator's behavioral contract executes the emitted command for both same-version and
changed-version releases.
