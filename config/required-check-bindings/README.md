# Required-check binding preparation

The `*-before.json` files are full authenticated organization ruleset observations;
`*-after.json` adds only the required-check `integration_id` fields, and
`*-rollback.json` preserves the original writable payload. None has been applied.

`observation.json` publishes aggregate producer coverage and hashes only. Full
cohort and check-run evidence is private and must not be committed here. The
renderer reports whether that evidence was supplied and validated; dry-run requires
it and explicitly rechecks it. See ADR0173 for the receipt location and live gates.
