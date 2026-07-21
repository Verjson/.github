# Enforce the Node release runtime floor — 2026-07-21

Fail reusable Node releases with a clear diagnostic before installing the locked
semantic-release toolchain when a caller selects an unsupported runtime. CI now
tests the exact `^22.14.0 or >=24.10.0` boundary tracked in #98.
