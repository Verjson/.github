---
id: 20260917T061500Z
title: The fleet inventory no longer reports an absent workflows directory as a gap
impact: patch
---

`scripts/fleet-contract-inventory.py` counted every repository whose
`.github/workflows` listing 404s as `unreachable`. Fourteen fleet repositories
answer that way — eleven have no workflows directory and three have no commits
at all — so the sweep reported fourteen gaps it did not have and exited nonzero
for a benign reason.

A 404 on a directory the org enumeration already listed with the same token is a
complete observation: there is nothing to inventory. It is now distinguished
from a failed call by the **HTTP status**, never by the prose, since GitHub
words an empty repository and a missing path differently and may reword either.
Any other status, and any failure carrying no status at all, still reports
`unreachable` — `workflows()` keeps its contract that `{}` means "no workflows"
and never also means "the listing call failed".

Part of #1364
