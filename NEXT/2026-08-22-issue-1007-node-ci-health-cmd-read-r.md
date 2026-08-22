---
date: 2026-08-22
issue: 1007
title: "fix(node-ci): use read -r for caller-supplied health commands"
---

`node-ci.yml`'s `db-health-cmd`/`cache-health-cmd` tokenization used `read -ra`
without `-r`, so a backslash in a caller-supplied health command would be
interpreted by `read` rather than reaching `docker exec` as a literal
character, contradicting the "reaches docker exec as literal argv" comment
and tests. Added `-r` to both `read` invocations.
