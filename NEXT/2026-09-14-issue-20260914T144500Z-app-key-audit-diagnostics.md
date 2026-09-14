---
date: 2026-09-14
id: 20260914T144500Z
title: Audit the declared App key environment and report why a verification failed
impact: patch
---

Part of [#1285](https://github.com/Verjson/.github/issues/1285).

`scripts/app-key-environment-audit.py` derived each canonical environment name as
`<role>-app` while `config/app-key-roles.json` carried an `environment` field of its own.
Two derivations of one fact drift silently: renaming a role environment in the manifest
would have left the audit querying the old name and reporting on an environment nobody
uses. The audit now reads the declared field, and `load_roles` rejects a canonical entry
whose declared environment does not match its role, so the convention is enforced in one
place instead of assumed in two. A `caller-owned` entry still names any environment the
calling repository owns.

When the audit cannot verify isolation it printed operator guidance and discarded the
exception, so a metadata-access failure, a malformed manifest and a genuinely
non-main-only branch policy were indistinguishable at the point an operator reads them.
The cause is now printed beside the guidance.
