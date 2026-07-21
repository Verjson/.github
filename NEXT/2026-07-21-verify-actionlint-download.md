# Verify the pinned actionlint archive before extraction — 2026-07-21

Pin the upstream SHA-256 digest for the actionlint v1.7.7 Linux amd64 archive
and verify it before extraction or execution. A corrupted or replaced download
now fails closed, with the installer behavior covered by an extracted-workflow
test. Closes #83.
