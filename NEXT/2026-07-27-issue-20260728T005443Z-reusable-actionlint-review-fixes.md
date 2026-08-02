---
date: 2026-07-27
id: 20260728T005443Z
title: Harden reusable actionlint after independent review
---

Inline actionlint's invalid-workflow fixtures so a reusable call never executes a
caller-controlled test script on the default self-hosted runner. Hosted calls now
require ShellCheck explicitly, with four existing intentional SC2016 literals
documented by line-scoped suppressions. The structural suite extracts and
mutation-tests the inline block and pins the hosted ShellCheck requirement.
