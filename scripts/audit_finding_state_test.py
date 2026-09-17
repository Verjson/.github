import hashlib
import importlib.util
import json
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


if __name__ == "__main__":
    unittest.main()
