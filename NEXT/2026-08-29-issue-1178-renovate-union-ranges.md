---
date: 2026-08-29
issue: 1178
impact: patch
title: Parse Renovate union version ranges safely
---

Accept Renovate update-table version ranges joined by escaped `||` operators while
continuing to reject unescaped cell delimiters, malformed escapes, and unsafe version
text.
