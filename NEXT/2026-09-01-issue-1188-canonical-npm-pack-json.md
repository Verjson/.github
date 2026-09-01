---
date: 2026-09-01
issue: 1188
impact: patch
title: Generate the canonical npm pack receipt parser
---

Own the type-surface contract's `npm pack --json` parser centrally and generate both its
consumer helper and byte-identity test from an immutable contract revision. The parser
accepts npm 11 array receipts and npm 12 package-keyed object receipts, while rejecting
missing or unsafe filenames, non-tarballs, multiple entries, and wrong-package tarballs
before a consumer joins or installs the reported path.
