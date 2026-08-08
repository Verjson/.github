---
date: 2026-08-08
issue: 650
title: Require dedicated App approval before native auto-merge
---

Make the receipt-bound authorization App publish and verify an exact-head approving review before its check can succeed, and reject promotion while GitHub still reports `REVIEW_REQUIRED`.

This preserves native auto-merge's ordinary-CI waiting without a runner or another paid review. Deployment requires granting the dedicated App pull-requests write permission and approving or reinstalling the App before the disabled AI workflows are enabled; see ADR 0079.
