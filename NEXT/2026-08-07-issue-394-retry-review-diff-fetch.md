---
date: 2026-08-07
issue: 394
title: Retry transient review-diff fetch failures
---

Retry bounded GitHub 5xx and transport failures while fetching both the AI
review diff and the privileged merge's complete pull-request file list, and
fail immediately on structural 4xx responses.

Exhausted retries now emit typed infrastructure-unavailable evidence instead of
resembling a substantive rejection. The diagnostics mask raw response content
and avoid retrying rate limits. This covers the transient HTTP 500 observed on
#518 and continues the fail-closed gate chain from #441, #452, and #384.
