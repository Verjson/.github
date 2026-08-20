---
date: 2026-08-20
id: 20260820T023000Z
title: Prune closed issues and refresh backlog status from live findings
---

`CLAUDE.md`'s Active Issues list carried #858 and #856 as open; both were
actually closed on 2026-08-16, days before this refresh, and had gone
unnoticed. Removed them and updated #931, #676, #699, #157, and #819/#810
with live findings from a PM sync: #931's quota cleared but a dangling
check-run is now the real blocker; #676's lane concept is done but `.github`'s
own caller still bypasses it; #699 has an interim-PAT PR open; #157's new
token doesn't cover 7 specific private repos; #819/#810 narrowed to two
residual decisions that are `.github`'s to make.
