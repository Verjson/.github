# Attribute red checks and preserve approval audit — 2026-07-30

Emit a compact, safely encoded snapshot of checks the merge gate classifies as failed so the payments reproduction can be diagnosed without guessing. When repository policy disables Actions-authored approvals, retain a non-blocking verdict as a head- and patch-id-bound audit comment while unexpected publication errors remain fail-closed. See #240, #242, ADR 0024, and ADR 0036.
