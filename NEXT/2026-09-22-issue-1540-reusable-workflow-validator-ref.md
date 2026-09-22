---
date: 2026-09-22
issue: 1540
impact: patch
title: Check out the App-key validator from its reusable workflow revision
---
Use the reusable workflow's repository and SHA when checking out the immutable AI-review key validator. The caller's workflow SHA can name a commit that does not exist in `Verjson/.github`, causing authorization to fail before review. Part of #1540; restores the source boundary recorded in ADR 0171.
