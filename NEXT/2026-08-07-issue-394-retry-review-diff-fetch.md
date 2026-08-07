---
date: 2026-08-07
issue: 394
title: Retry transient review-diff fetch failures
---

Retry bounded GitHub 5xx and transport failures while fetching the AI review diff, and fail immediately on structural 4xx responses.

Exhausted retries now emit a typed infrastructure-unavailable signal instead of resembling a substantive rejection. The diagnostics mask raw response content and avoid retrying rate limits. This continues the fail-closed gate chain from #441, #452, and #384.
