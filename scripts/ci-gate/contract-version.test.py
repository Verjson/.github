#!/usr/bin/env python3
"""Regression suite for scripts/contract-version.py (Verjson/.github#1374)."""
import importlib.util
import pathlib
import sys
import unittest

_root = pathlib.Path(__file__).resolve().parents[2]
_spec = importlib.util.spec_from_file_location(
    "contract_version", _root / "scripts" / "contract-version.py")
cv = importlib.util.module_from_spec(_spec)
# Registered before execution: `@dataclasses.dataclass` under
# `from __future__ import annotations` resolves field types through
# `sys.modules[cls.__module__]`, which is absent for a module loaded straight
# from a path.
sys.modules["contract_version"] = cv
_spec.loader.exec_module(cv)


def rel(version, commit_char="a", published="2026-01-01"):
    return cv.Release(version=version, commit=commit_char * 40, published=published)


class SupportedWindow(unittest.TestCase):
    def test_window_never_refuses_a_version_package_retention_still_keeps(self):
        # Three minor lines, three releases: "current and previous minor" alone
        # would refuse v3.0.0 while the keep-3 retention policy still considers
        # it current, stranding a consumer the org calls supported.
        releases = [rel("v2.9.0"), rel("v3.0.0"), rel("v3.1.0"), rel("v3.2.0")]
        self.assertEqual(
            cv.supported_versions(releases), {"v3.0.0", "v3.1.0", "v3.2.0"})


class DeprecationClock(unittest.TestCase):
    def test_a_version_pushed_out_of_the_window_expires_90_days_after_the_release_that_did_it(self):
        # v3.0.0 is still supported at v3.2.0 (it is one of the newest three);
        # v3.3.0, published 2026-03-01, is what pushes it out. The deprecation
        # error has to name a date a maintainer can act on, and that date is a
        # function of release metadata rather than a stored deadline.
        releases = [
            rel("v3.0.0", published="2026-01-01"),
            rel("v3.1.0", published="2026-01-15"),
            rel("v3.2.0", published="2026-02-01"),
            rel("v3.3.0", published="2026-03-01"),
        ]
        verdict = cv.classify("v3.0.0", releases, today="2026-04-01")
        self.assertEqual(verdict.state, cv.DEPRECATED)
        self.assertEqual(verdict.expires_on, "2026-05-30")


if __name__ == "__main__":
    unittest.main()
