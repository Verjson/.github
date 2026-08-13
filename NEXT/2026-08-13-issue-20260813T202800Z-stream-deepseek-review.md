---
date: 2026-08-13
id: 20260813T202800Z
title: Stream long-running DeepSeek code reviews
impact: patch
---

DeepSeek code reviews now consume bounded server-sent events and retain exact
usage, budget, model, JSON, and tool-free validation, preventing long reviews
from losing their entire verdict to an idle HTTP connection reset.

The stream parser fails closed on incomplete termination, missing or duplicate
usage evidence, wrong-model chunks, tool calls, malformed events, trailing data,
invalid UTF-8, and responses beyond the bounded output envelope.
Provider-request notices record only the transport, selected model, terminal
state, elapsed seconds, and exception type; prompts, diffs, keys, response
content, and exception messages remain out of diagnostic metadata.
