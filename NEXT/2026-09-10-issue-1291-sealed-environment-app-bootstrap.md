---
date: 2026-09-10
issue: 1291
title: Sealed environment App bootstrap
---

Add a temporary protected-main bootstrap that encrypts existing App keys with reviewed environment public keys. A local authenticated importer checks workflow/artifact provenance and fresh main-only destinations before writing ciphertext; separate environment-bound App scope proofs and metadata receipts gate completion. Broader secret copies remain available until a separately reviewed cohort migration.
