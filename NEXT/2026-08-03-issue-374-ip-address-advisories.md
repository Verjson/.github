---
date: 2026-08-03
issue: 374
title: Time-box npm-bundled ip-address advisory exceptions
---

Accept the three newly published `ip-address` advisories through 2026-08-10.
The affected copy is bundled in npm 11.19.0 behind SOCKS proxy support, while
trusted release jobs use organization-controlled endpoints without a SOCKS
proxy. npm 11 has no fixed release yet, bundled dependencies cannot be
overridden, and the release plugin does not support npm 12.
