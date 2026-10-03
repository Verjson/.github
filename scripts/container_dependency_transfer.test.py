import os
import subprocess
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).with_name("container_dependency_transfer.py")


class ContainerDependencyTransferTests(unittest.TestCase):
    def setUp(self) -> None:
        self.directory = tempfile.TemporaryDirectory()
        self.root = Path(self.directory.name)
        self.source = self.root / "private-package.tgz"
        self.source.write_bytes(b"private package contents\x00" * 128)
        self.encrypted = self.root / "private-package.tgz.enc"
        self.decrypted = self.root / "restored-package.tgz"
        self.key = "a1" * 32

    def tearDown(self) -> None:
        self.directory.cleanup()

    def run_transfer(self, operation: str, source: Path, destination: Path, key: str | None = None):
        environment = os.environ.copy()
        if key is not None:
            environment["TRANSFER_KEY"] = key
        return subprocess.run(
            [
                "python3",
                str(SCRIPT),
                operation,
                "--source",
                str(source),
                "--destination",
                str(destination),
            ],
            env=environment,
            capture_output=True,
            text=True,
            check=False,
        )

    def test_private_package_bytes_are_authenticated_and_round_trip(self) -> None:
        encrypted = self.run_transfer("encrypt", self.source, self.encrypted, self.key)
        self.assertEqual(encrypted.returncode, 0, encrypted.stderr)
        payload = self.encrypted.read_bytes()
        self.assertNotIn(b"private package contents", payload)

        decrypted = self.run_transfer("decrypt", self.encrypted, self.decrypted, self.key)
        self.assertEqual(decrypted.returncode, 0, decrypted.stderr)
        self.assertEqual(self.decrypted.read_bytes(), self.source.read_bytes())

    def test_wrong_key_fails_without_creating_plaintext(self) -> None:
        encrypted = self.run_transfer("encrypt", self.source, self.encrypted, self.key)
        self.assertEqual(encrypted.returncode, 0, encrypted.stderr)

        decrypted = self.run_transfer("decrypt", self.encrypted, self.decrypted, "b2" * 32)
        self.assertNotEqual(decrypted.returncode, 0)
        self.assertFalse(self.decrypted.exists())

    def test_tampered_ciphertext_fails_before_plaintext_is_written(self) -> None:
        encrypted = self.run_transfer("encrypt", self.source, self.encrypted, self.key)
        self.assertEqual(encrypted.returncode, 0, encrypted.stderr)
        tampered = bytearray(self.encrypted.read_bytes())
        tampered[len(tampered) // 2] ^= 1
        self.encrypted.write_bytes(tampered)

        decrypted = self.run_transfer("decrypt", self.encrypted, self.decrypted, self.key)
        self.assertNotEqual(decrypted.returncode, 0)
        self.assertFalse(self.decrypted.exists())

    def test_destination_is_never_overwritten(self) -> None:
        self.encrypted.write_text("preserve", encoding="utf-8")

        encrypted = self.run_transfer("encrypt", self.source, self.encrypted, self.key)

        self.assertNotEqual(encrypted.returncode, 0)
        self.assertEqual(self.encrypted.read_text(encoding="utf-8"), "preserve")

    def test_invalid_key_is_rejected(self) -> None:
        encrypted = self.run_transfer("encrypt", self.source, self.encrypted, "not-a-key")

        self.assertNotEqual(encrypted.returncode, 0)
        self.assertFalse(self.encrypted.exists())


if __name__ == "__main__":
    unittest.main()
