---
date: 2026-08-20
issue: 950
impact: patch
title: Write the deferred arm-receipt artifact ID atomically
---

`verify-arm-receipt.sh` recorded the artifact ID for deferred deletion with a
direct `printf` to the target path; a partial write (e.g. ENOSPC/EIO) could
leave a truncated ID for the later deletion step to read. The write now goes
through a same-directory temp file and an atomic rename, so a failure can
never leave a truncated ID at the target path.
