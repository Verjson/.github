# Keep the NEXT fast lane limited to flat fragments — 2026-07-21

Tighten the merge gate's documentation allowlist so only flat `NEXT/*.md` files
qualify for no-model review. Nested paths under `NEXT/` now follow the normal AI
review lane, matching the fragment layout documented by the repository. Closes
#75; amends ADR 0007.
