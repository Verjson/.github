---
date: 2026-10-03
id: 20261003T003813Z
refs: 1679
impact: patch
title: Encrypt private dependency cache transfers in protected builds
---

The generated protected Node CI workflow now transfers private dependency cache contents between jobs as authenticated ciphertext. It passes the decryption key only through the current workflow run and removes the plaintext archive before saving the run-scoped cache. A compatibility contract checks the generated workflow against the canonical secretless workflow and verifies that the encrypted archive is the cached payload.
