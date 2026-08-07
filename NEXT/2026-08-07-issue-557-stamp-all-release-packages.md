---
date: 2026-08-07
issue: 557
title: Verify every published package at the dispatched version
summary: Stamp every configured release package before running the verification suite.
---

Multi-package release callers now apply the dispatched version to the root and every
configured secondary package before tests run, so verification observes the same
package versions that the reusable publisher will publish.
