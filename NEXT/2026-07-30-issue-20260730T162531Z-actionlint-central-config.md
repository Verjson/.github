---
date: 2026-07-30
id: 20260730T162531Z
title: Apply the central actionlint runner policy to reusable callers
---

The reusable actionlint workflow now loads its config from the immutable
workflow revision by default, while allowing callers to select their own config
path when necessary. Its behavioral contract proves that an undeclared custom
runner label fails linting while the governed `GCP` label passes. Closes #208.
