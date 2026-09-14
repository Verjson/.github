---
date: 2026-09-14
id: 20260914T143000Z
title: Widen the App key workflow scan to every spelling a binding can take
impact: patch
---

Part of [#1285](https://github.com/Verjson/.github/issues/1285).

The scan that enumerates `.github/workflows` for App private key bindings only saw one
spelling of a binding, so three real ones passed it silently and read as full coverage —
the exact failure mode the enumeration replaced a hand-written list to avoid.

- A workflow file named `*.yaml` was never opened, though GitHub Actions runs both
  extensions. Both are scanned now, in one sorted pass.
- `secrets['NAME']` index syntax is valid GitHub expression syntax and the literal-dot
  pattern did not match it. Both spellings are the same binding and are recognized
  as one.
- Detection keyed on the `APP_PRIVATE_KEY` suffix, so `RELEASE_APP_KEY_PEM`, a plain
  `..._APP_KEY` and a lowercase `secrets.x_app_private_key` were invisible. Any secret
  name containing `APP` and `KEY`, case-insensitively, is now an App key; the canonical
  roles classify exactly as before.
- A key read from a workflow-level `env:` block outside `jobs:` contributed **zero**
  bindings, because the per-job render never saw it — and a workflow-level read is the
  one place no `environment:` can confine the key at all. Each file's mentioned keys are
  now reconciled against what its jobs captured, and a key no job accounts for is an
  error. That also closes the path where a file with no `jobs:` key at all scanned as
  empty rather than as a failure.
