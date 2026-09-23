---
date: 2026-09-23
issue: 1436
impact: patch
title: Prove standalone shell lint coverage
---

The platform Actions group now invokes its warning-level tracked-shell lint through a focused runner with executable conformance coverage. Pull-request and push triggers cover tracked shell scripts outside the conventional script directories.

Paired fixtures prove that tracked standalone scripts fail on ShellCheck warnings, untracked scripts remain outside the index-bound scan, filenames with spaces are preserved, and repositories without tracked shell scripts remain a successful no-op.
