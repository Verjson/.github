import hashlib
import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
STATE_PATH = ROOT / "scripts/audit-finding-state.py"
SPEC = importlib.util.spec_from_file_location("audit_finding_state", STATE_PATH)
STATE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(STATE)


def fingerprint(finding):
    return hashlib.sha256(finding.encode("utf-8")).hexdigest()


def expectation(finding, *, issue=1401, reason="tracked", expires="2099-01-01"):
    return {
        "fingerprint": fingerprint(finding),
        "finding": finding,
        "issue": issue,
        "reason": reason,
        "expires": expires,
    }


def emitter(*, findings=(), status=1, stdout=""):
    """A stand-in audit that prints the given findings the way the real one does."""
    program = (
        "import sys\n"
        f"sys.stdout.write({stdout!r})\n"
        f"for line in {list(findings)!r}:\n"
        "    sys.stderr.write('ERROR: ' + line + '\\n')\n"
        f"raise SystemExit({status})\n"
    )
    return [sys.executable, "-c", program]


class AuditFindingStateTest(unittest.TestCase):
    def setUp(self):
        self.workspace = tempfile.TemporaryDirectory()
        self.addCleanup(self.workspace.cleanup)
        self.root = Path(self.workspace.name)

    def expectations_file(self, entries, *, audit="arm", schema_version=1, raw=None):
        path = self.root / "expected-findings.json"
        if raw is not None:
            path.write_text(raw, encoding="utf-8")
            return path
        document = {"schema_version": schema_version, "audits": {audit: list(entries)}}
        path.write_text(json.dumps(document), encoding="utf-8")
        return path

    def run_state(self, *, entries, command, audit="arm", expectations=None, env=None):
        path = expectations if expectations is not None else self.expectations_file(entries, audit=audit)
        completed = subprocess.run(
            [sys.executable, str(STATE_PATH), "--audit", audit, "--expectations", str(path), "--"]
            + command,
            capture_output=True,
            text=True,
            env=env,
        )
        return completed

    def test_a_persisting_recorded_finding_is_quiet(self):
        finding = "armed default branches without canonical deterministic required CI: missing=1"
        completed = self.run_state(
            entries=[expectation(finding)],
            command=emitter(findings=[finding]),
        )
        self.assertEqual(completed.returncode, 0, completed.stderr)
        state = json.loads(completed.stdout)
        self.assertEqual(state["verdict"], "match")

    def test_a_newly_appearing_finding_is_loud(self):
        recorded = "armed default branches without canonical deterministic required CI: missing=1"
        appeared = "armed default branches without canonical deterministic required CI: missing=2"
        completed = self.run_state(
            entries=[expectation(recorded)],
            command=emitter(findings=[appeared]),
        )
        self.assertEqual(completed.returncode, 1, completed.stdout)
        state = json.loads(completed.stdout)
        self.assertEqual(state["verdict"], "drift")
        self.assertEqual(state["new"], [fingerprint(appeared)])

    def test_a_recorded_finding_that_no_longer_reproduces_is_loud(self):
        recorded = "armed default branches without canonical deterministic required CI: missing=1"
        completed = self.run_state(
            entries=[expectation(recorded)],
            command=emitter(findings=[], status=0),
        )
        self.assertEqual(completed.returncode, 1, completed.stdout)
        state = json.loads(completed.stdout)
        self.assertEqual(state["verdict"], "drift")
        self.assertEqual(state["stale"], [fingerprint(recorded)])

    def test_an_expired_waiver_stops_keeping_its_finding_quiet(self):
        finding = "armed default branches without canonical deterministic required CI: missing=1"
        completed = self.run_state(
            entries=[expectation(finding, expires="2000-01-01")],
            command=emitter(findings=[finding]),
        )
        self.assertEqual(completed.returncode, 1, completed.stdout)
        state = json.loads(completed.stdout)
        self.assertEqual(state["verdict"], "drift")
        self.assertEqual(state["expired"], [fingerprint(finding)])

    def test_an_unreadable_expectation_file_fails_closed(self):
        completed = self.run_state(
            entries=[],
            command=emitter(findings=[], status=0),
            expectations=self.root / "absent.json",
        )
        self.assertEqual(completed.returncode, 2, completed.stdout)
        self.assertIn("audit-state-undetermined", completed.stderr)

    def test_an_audit_with_no_recorded_expectation_fails_closed(self):
        path = self.expectations_file([], audit="other")
        completed = self.run_state(entries=[], command=emitter(status=0), expectations=path)
        self.assertEqual(completed.returncode, 2, completed.stdout)
        self.assertIn("no recorded expectation", completed.stderr)

    def test_a_recorded_finding_whose_digest_disagrees_fails_closed(self):
        entry = expectation("armed default branches: missing=1")
        entry["finding"] = "a different finding than the digest describes"
        completed = self.run_state(entries=[entry], command=emitter(status=0))
        self.assertEqual(completed.returncode, 2, completed.stdout)
        self.assertIn("does not describe", completed.stderr)

    def test_an_expectation_entry_missing_its_tracking_issue_fails_closed(self):
        entry = expectation("armed default branches: missing=1")
        del entry["issue"]
        completed = self.run_state(entries=[entry], command=emitter(status=0))
        self.assertEqual(completed.returncode, 2, completed.stdout)
        self.assertIn("audit-state-undetermined", completed.stderr)

    def test_an_audit_that_failed_without_reporting_a_finding_fails_closed(self):
        completed = self.run_state(entries=[], command=emitter(findings=[], status=3))
        self.assertEqual(completed.returncode, 2, completed.stdout)
        self.assertIn("reported no finding", completed.stderr)

    def test_an_audit_that_succeeded_while_reporting_a_finding_fails_closed(self):
        finding = "armed default branches: missing=1"
        completed = self.run_state(
            entries=[expectation(finding)],
            command=emitter(findings=[finding], status=0),
        )
        self.assertEqual(completed.returncode, 2, completed.stdout)
        self.assertIn("succeeded while reporting", completed.stderr)

    def test_an_audit_command_that_cannot_be_started_fails_closed(self):
        completed = self.run_state(
            entries=[], command=[str(self.root / "no-such-audit")]
        )
        self.assertEqual(completed.returncode, 2, completed.stdout)
        self.assertIn("could not be started", completed.stderr)

    def summary_of(self, *, entries, command, audit="arm"):
        summary = self.root / "summary.md"
        environment = dict(os.environ, GITHUB_STEP_SUMMARY=str(summary))
        completed = self.run_state(entries=entries, command=command, audit=audit, env=environment)
        return completed, summary.read_text(encoding="utf-8") if summary.exists() else ""

    def test_the_step_summary_names_a_new_finding_and_its_digest(self):
        appeared = "armed default branches without canonical deterministic required CI: missing=2"
        completed, summary = self.summary_of(entries=[], command=emitter(findings=[appeared]))
        self.assertEqual(completed.returncode, 1, completed.stdout)
        self.assertIn("drift", summary)
        self.assertIn(fingerprint(appeared), summary)
        self.assertIn(appeared, summary)

    def test_the_step_summary_records_a_quiet_match_too(self):
        finding = "armed default branches without canonical deterministic required CI: missing=1"
        completed, summary = self.summary_of(
            entries=[expectation(finding)], command=emitter(findings=[finding])
        )
        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertIn("match", summary)
        self.assertIn(fingerprint(finding), summary)

    def test_a_finding_cannot_inject_an_actions_workflow_command(self):
        hostile = "::error::spoofed" + chr(13) + "::set-output name=x::y"
        completed, summary = self.summary_of(entries=[], command=emitter(findings=[hostile]))
        self.assertEqual(completed.returncode, 1, completed.stdout)
        for line in summary.splitlines():
            self.assertFalse(line.startswith("::"), line)
        self.assertNotIn(chr(13), summary)

    def test_an_undetermined_run_says_so_in_the_step_summary(self):
        completed, summary = self.summary_of(entries=[], command=emitter(findings=[], status=3))
        self.assertEqual(completed.returncode, 2, completed.stdout)
        self.assertIn("undetermined", summary)
        self.assertIn("reported no finding", summary)


if __name__ == "__main__":
    unittest.main()
