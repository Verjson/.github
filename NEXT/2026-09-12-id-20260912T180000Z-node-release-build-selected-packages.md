---
date: 2026-09-12
id: 20260912T180000Z
impact: patch
title: build every selected Node package before script-disabled publication
summary: The reusable node-release contract now builds each selected nested package after stamping and before npm pack, preserving root release callers while allowing independently generated component callers to publish their own dist output.
---
