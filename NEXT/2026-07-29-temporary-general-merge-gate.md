## Temporarily route Verjson merge gates through general runners

The AI merge gate and this repository’s shell validation now use the Verjson
organization’s provider-neutral `general` DigitalOcean pool. This speed-first
exception keeps DigitalOcean contexts and GitHub runner registrations
organization-isolated, but temporarily removes disposable-host isolation for
public PR processing. Public Verjson repositories are temporarily admitted to
the general runner group, and `VERJSON_RUNNER_ISOLATED` points to `general`.

Issue #204 records the required security restoration.
