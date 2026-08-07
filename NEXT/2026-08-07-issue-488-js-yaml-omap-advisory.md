---
date: 2026-08-07
title: Bump js-yaml past the omap DoS advisory that had reddened every PR
issue: 488
---

`GHSA-5p4m-2wfm-xmqj` was published against `js-yaml` (quadratic CPU consumption resolving
`!!omap`, CVE-2026-59870 unbackported, CVSS 7.5, range `>=4.0.0 <4.3.1`). Nothing in this
repository changed; the advisory appeared, `scripts/release-tooling-audit.sh` failed closed
as designed, and `shell-tests` went red on `main` and on every open pull request at once.

`js-yaml` is transitive — `semantic-release@25.0.8 > … > cosmiconfig > js-yaml ^4.1.0` — and
4.3.1 satisfies that range, so the lockfile alone moves. No `overrides`, no
`semantic-release` bump, and deliberately **no allowlist entry**: the allowlist exists for
advisories whose fix is not installable (the `brace-expansion` and `ip-address` entries are
all bundled inside npm's own CLI, where `overrides` cannot reach them). Excusing an advisory
that upstream has already fixed would spend a dated exception on nothing.

`node_modules/` is now ignored. Verifying this fix means running the audit, which installs
~30 MB into `.github/release-tooling/node_modules/`; untracked, it sat in `git status`
one `git add -A` away from being committed.
