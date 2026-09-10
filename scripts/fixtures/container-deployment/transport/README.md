# Historical runner manifest fixture

`runner-v0.2.1-manifest.json` preserves the exact release asset bytes collected for
runner issue #197: current repository `Verjson/verjson-git-runners`, repository
ID `1301436066`, release asset ID `532627568`, version `v0.2.1`. Its SHA-256 is
`4f5bb96e1fe07f7b56cfe124206ed85c4e59b9715b3b4e18b3054d890dd1ad32`.

The manifest names the historical `Verjson/verjson-github-runner` signed source.
Do not reformat it or rewrite that source name. The test proves current API
identity and historical provenance stay separate; GitHub and the attestation
verifier are mocked, so this fixture is not live acceptance evidence.
