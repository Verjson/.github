---
date: 2026-09-23
issue: 1397
title: Harden public-cache file and mount validation
impact: patch
---

The Node CI compatibility sandbox now carries a malicious-cache regression proving that
a top-level `content-v2` file symlink cannot copy host content into the sandbox. Its
public-cache mount allowlist is also documented and checked against the installed
Bubblewrap option synopsis, including negative controls for arity drift, unsupported
flags, truncated arguments, and replacing `lstat` with a symlink-following check. This
also resolves #1419.
