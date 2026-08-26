---
date: 2026-08-26
id: 20260826T170000Z
impact: patch
title: Bind runner deployment to verified review evidence
---
Runner deployment now binds independent code, security, and AI review artifacts to GitHub-owned exact-head authority, separates uncredentialed review analysis from protected App publishing, limits each repository-bound publisher token to checks writes, and separates DigitalOcean from runner-registration credentials.

This completes the trust-boundary amendment tracked by #629 without modifying its earlier changelog entry.
