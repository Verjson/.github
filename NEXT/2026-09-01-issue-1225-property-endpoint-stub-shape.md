---
date: 2026-09-01
issue: 1225
impact: patch
title: audit test fixture rejects an unrecognized properties-endpoint shape instead of silently misparsing it
---

`scripts/required-checks-audit.test.sh`'s `gh` stub derived the repository name
for `GET /repos/{org}/{repo}/properties/values` from `${args[1]}` without
checking the endpoint had that shape. Anything else landing there would still
parse to some string and silently answer with the wrong repository's (or the
shared) properties file instead of failing — masking a fixture/production
drift behind a passing suite for the wrong reason.

The stub now asserts `repos/<org>/<repo>/properties/values` before parsing it,
and faults loudly (`unexpected properties endpoint: ...`, exit 65) on anything
else. This is a test-fixture hardening only; the production script
(`scripts/required-checks-audit.sh:144`) already always emits the well-formed
shape, so no caller behavior changes.

Found as an AI-review follow-up on PR #1222.
