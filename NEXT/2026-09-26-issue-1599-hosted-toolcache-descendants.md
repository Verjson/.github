---
date: 2026-09-26
issue: 1599
impact: patch
title: node-ci-protected admits the whole hosted tool cache tree, not only its root
---
`node-ci-protected.yml` no longer fails every GitHub-hosted protected type-surface run with `setup-node lexical PATH ancestry has unsafe ownership mode`. When the trusted tool root is the admitted `/opt/hostedtoolcache` convention (uid 0 or 1001, gid 0, mode 0777), the write-bit requirement is relaxed for every resolved path under it: PATH ancestry, the npm/node executables, and the mounted tool prefix tree. Owner allowlisting, symlink containment, special-file rejection, and the exact-root admission stay fail-closed, and every other tool root remains strict.

#1603 admitted only the literal root component, but a probe on `ubuntu-latest` shows every descendant of `/opt/hostedtoolcache/node` (2204 directories, 9549 files, 6 symlinks) is uid 1001 gid 1000 mode 0777, so setup-node's resolved `node/<version>/x64` tree could never pass a per-descendant unwritable check there. The new adversarial test models that measured shape, rejects a foreign owner inside the admitted tree, and rejects world-writable descendants under a strict root at the hosted path. Regenerated from `scripts/gen-node-ci-protected.py`.
