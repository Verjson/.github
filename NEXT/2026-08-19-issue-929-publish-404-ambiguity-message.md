---
date: 2026-08-19
issue: 929
impact: patch
title: Clarify that a post-publish-failure 404 is not proof a package version is unpublished
---

`node-release.yml`'s publish-failure remedy treated an `npm view` 404 as proof
the version was never published. GitHub Packages also returns 404 for a
private package the job's token cannot read, so a 404 could equally reflect
an authorization gap. The error message now says so explicitly instead of
asserting a confirmed-missing version.
