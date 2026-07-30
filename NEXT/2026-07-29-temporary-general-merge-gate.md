## Temporarily route Verjson merge gates through general runners

The AI merge gate now uses the Verjson organization’s provider-neutral
`general` DigitalOcean pool for public and private repositories. This
speed-first exception keeps DigitalOcean contexts and GitHub runner
registrations organization-isolated, but temporarily removes disposable-host
isolation for public PR gate processing.

Issue #204 records the required security restoration.
