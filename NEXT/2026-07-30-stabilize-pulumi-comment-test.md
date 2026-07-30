# Stabilize Pulumi workflow assertions — 2026-07-30

Make the Pulumi credential-boundary test search extracted jobs without a
`pipefail`-sensitive producer pipeline, and cover large job blocks that
previously turned successful early matches into intermittent failures (#199).
