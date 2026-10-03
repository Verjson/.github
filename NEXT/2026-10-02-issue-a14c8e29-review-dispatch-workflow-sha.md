---
date: 2026-10-02
id: a14c8e29
impact: patch
title: Guard direct review dispatch provenance
---

Resolve the direct-dispatch verifier from GitHub's immutable `github.workflow_sha`; admit direct runs only from protected default `main` with the `ai-review-app` environment, before verifier checkout or execution. Reject alternate environments at preflight, App-key, and completion boundaries for every dispatch, including reusable calls carrying `contract_ref`; the exact guard test rejects disjunctive bypasses. Keep the trusted dispatcher on the repository default branch. The observed admission failure was an arm-run provenance and receipt identity mismatch, so the empty SHA has not been established as its cause.
