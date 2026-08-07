---
date: 2026-08-07
issue: 475
title: Retry transient trusted merge dispatch failures
---

Retry bounded GitHub 5xx and transport failures while dispatching the trusted merge continuation, while failing immediately on structural 4xx responses.

Ambiguous duplicate dispatches remain safe because the continuation revalidates the source run and expected head. Exhaustion is typed as infrastructure-unavailable without exposing raw response content or misrepresenting the completed model verdict. This follows the review-input retry from #394.
