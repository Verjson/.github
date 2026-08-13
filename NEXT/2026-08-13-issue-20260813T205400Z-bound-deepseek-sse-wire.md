---
date: 2026-08-13
id: 20260813T205400Z
title: Scale the DeepSeek SSE wire bound with output tokens
impact: patch
---

DeepSeek review streams now allow bounded SSE and JSON framing overhead in
proportion to the existing maximum output-token envelope, so long reasoning
streams can reach their final verdict without weakening token, cost, model,
tool-call, or structured-output validation.

The 64 MiB maximum permits up to 1 KiB of streamed wire data per independently
bounded output token and still fails closed on an unbounded provider stream.
