# Nuremberg development services

Last verified: **2026-09-07**. Provisioning implementation:
[Verjson/verjson-cli](https://github.com/Verjson/verjson-cli).

## Endpoints

| Service | Endpoint | Verified state |
| --- | --- | --- |
| GitLab CE | <https://git.159-195-78-163.nip.io> | Sign-in page returns HTTP 200 |
| GitLab REST API | `https://git.159-195-78-163.nip.io/api/v4` | API base; authenticated API use not tested |
| GitLab SSH clone | `ssh://git@git.159-195-78-163.nip.io:30022/<group>/<repository>.git` | Configured port; clone not tested |
| Nexus UI | <https://nexus.159-195-78-163.nip.io> | HTTP 200 |
| Nexus REST API | `https://nexus.159-195-78-163.nip.io/service/rest/v1` | Authenticated repository inventory queried successfully |
| npm hosted registry | `https://nexus.159-195-78-163.nip.io/repository/npm-hosted/` | Awaiting provisioning; HTTP 404 |
| Docker registry | `docker.nexus.159-195-78-163.nip.io` | Awaiting provisioning; `/v2/` returns HTTP 502 |
| PyPI publishing | `https://nexus.159-195-78-163.nip.io/repository/pypi-hosted/` | Awaiting provisioning |
| PyPI package index | `https://nexus.159-195-78-163.nip.io/repository/pypi-hosted/simple/` | Awaiting provisioning |
| S3 API | <https://s3.159-195-78-163.nip.io> | `/minio/health/live` returns HTTP 200 |

HTTPS checks use normal certificate validation. Health checks establish
reachability only; they do not verify authentication, persistence, or backups.

## Registry setup status

The Nexus API reports that its Community Edition EULA has not been accepted.
The bootstrap job stopped at that prerequisite, and `npm-hosted`,
`docker-hosted`, and `pypi-hosted` do not yet exist. The client examples below
describe the intended endpoints and should be used after provisioning is
verified. PyPI publishing and its package index are two interfaces to the same
`pypi-hosted` repository.

Registry readiness and consumer integration are coordinated in
[#1264](https://github.com/Verjson/.github/issues/1264). Documentation updates
are tracked in [#1266](https://github.com/Verjson/.github/issues/1266).

## Client settings

Use a dedicated publishing account with permissions for the intended
repository. Supply credentials through your local credential store or CI secret
mechanism; do not commit them with these examples.

### npm

For packages in the `@verjson` scope, a project `.npmrc` can contain:

```ini
@verjson:registry=https://nexus.159-195-78-163.nip.io/repository/npm-hosted/
```

For an individual publish, select the hosted registry explicitly:

```sh
npm publish --registry=https://nexus.159-195-78-163.nip.io/repository/npm-hosted/
```

This is a hosted repository, not an npmjs proxy or group. It does not provide
arbitrary public npm dependencies. Authentication configuration must match the
Nexus authentication methods enabled by the platform team.

### Docker

```sh
docker login docker.nexus.159-195-78-163.nip.io
docker tag example:1.0.0 docker.nexus.159-195-78-163.nip.io/example:1.0.0
docker push docker.nexus.159-195-78-163.nip.io/example:1.0.0
docker pull docker.nexus.159-195-78-163.nip.io/example:1.0.0
```

Use the registry hostname without a `/repository/docker-hosted/` path. The
external connection uses HTTPS on port 443.

### Python / PyPI

Publish distribution files using Twine:

```sh
python -m twine upload \
  --repository-url https://nexus.159-195-78-163.nip.io/repository/pypi-hosted/ \
  dist/*
```

Install from the simple package index:

```sh
python -m pip install \
  --index-url https://nexus.159-195-78-163.nip.io/repository/pypi-hosted/simple/ \
  your-package
```

The hosted index contains uploaded packages only. Use `--index-url` for an
explicit package source; adding a private registry as `--extra-index-url` can
allow a public package with the same name to be selected. Dependency resolution
that combines public and private sources requires a separately configured and
reviewed proxy/group strategy.

## Verification and updates

Check HTTPS reachability without bypassing certificate validation. Registry
verification should include an authenticated upload and download of a uniquely
named test package/image, an integrity check, and removal of only those test
artifacts. Record which of these checks passed when updating the status above.
Do not infer successful publishing from the Nexus UI being reachable.
