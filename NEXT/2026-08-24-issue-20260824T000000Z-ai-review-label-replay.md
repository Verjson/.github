---
date: 2026-08-24
id: 20260824T000000Z
impact: patch
title: Consume synchronized AI-review authorization
---

Treat a current maintainer-authorized `ai-review` label as explicit authorization for a synchronized exact head, while consuming and verifying the label before provider spend so it cannot be replayed across later heads. See ADR 0121 and issue #991.
