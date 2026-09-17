# Required-check binding preparation

The `*-before.json` files are full authenticated organization ruleset observations;
`*-after.json` adds only the required-check `integration_id` fields, and
`*-rollback.json` preserves the original writable payload. Both prepared payloads
have since been applied: as of 2026-09-17 rulesets `20513599` and `20515817` match
their `*-after.json` byte-for-byte, so `dry-run` now fails closed on the changed
preimage. This rollout is consumed; see ADR0190 for the omitted `core-checks-actions`
ruleset and its separate preparation.

`observation.json` publishes aggregate producer coverage and hashes only. Full
cohort and check-run evidence is private and must not be committed here. The
renderer reports whether that evidence was supplied and validated; dry-run requires
it and explicitly rechecks it. See ADR0173 for the receipt location and live gates.
