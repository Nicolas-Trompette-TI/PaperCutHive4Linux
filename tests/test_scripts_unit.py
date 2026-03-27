import os
import subprocess
import tempfile
import unittest
from pathlib import Path


REPO = Path(__file__).resolve().parents[1]
SCRIPTS = REPO / "scripts"
RELEASE = REPO / "release"
EXT_ID = "pdlopiakikhioinbeibaachakgdgllff"
JWT_FIXTURE = (
    "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9."
    "eyJzdWIiOiJ1bml0LXRlc3QiLCJvcmdJZCI6IjEwMTk2YjA0In0."
    "dW5pdC10ZXN0LXNpZw"
)


def run_cmd(args, env=None, timeout=60):
    merged_env = os.environ.copy()
    if env:
        merged_env.update(env)
    return subprocess.run(
        args,
        cwd=REPO,
        env=merged_env,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        timeout=timeout,
        check=False,
    )


class ScriptUnitTests(unittest.TestCase):
    def make_extension_profile(self, root: Path) -> Path:
        scan = root / "Default" / "Sync Extension Settings" / EXT_ID
        scan.mkdir(parents=True, exist_ok=True)
        (scan / "000003.log").write_text(f"prefix {JWT_FIXTURE} suffix\n", encoding="utf-8")
        return root

    def test_install_hive_cups_backend_requires_org(self):
        result = run_cmd([str(SCRIPTS / "install_hive_cups_backend.sh")])
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("--org-id is required", result.stdout)

    def test_install_hive_cups_backend_dry_run(self):
        result = run_cmd(
            [
                str(SCRIPTS / "install_hive_cups_backend.sh"),
                "--org-id",
                "10196b04",
                "--dry-run",
            ]
        )
        self.assertEqual(result.returncode, 0, msg=result.stdout)
        self.assertIn("[dry-run] sudo apt-get update -y", result.stdout)
        self.assertIn("Queue created: PaperCut-Hive-Lite", result.stdout)

    def test_import_hive_jwt_from_extension_dry_run(self):
        with tempfile.TemporaryDirectory() as td:
            profile = self.make_extension_profile(Path(td))
            result = run_cmd(
                [
                    str(SCRIPTS / "import_hive_jwt_from_extension.sh"),
                    "--profile-dir",
                    str(profile),
                    "--linux-user",
                    "nobody",
                    "--dry-run",
                ]
            )
            self.assertEqual(result.returncode, 0, msg=result.stdout)
            self.assertIn("Detected extension JWT", result.stdout)
            self.assertIn("Dry-run: token not written.", result.stdout)

    def test_secret_store_dry_run_from_extension(self):
        with tempfile.TemporaryDirectory() as td:
            profile = self.make_extension_profile(Path(td))
            result = run_cmd(
                [
                    str(SCRIPTS / "papercut_secret_store.sh"),
                    "--org-id",
                    "10196b04",
                    "--linux-user",
                    "nobody",
                    "--from-extension",
                    "--profile-dir",
                    str(profile),
                    "--dry-run",
                ]
            )
            self.assertEqual(result.returncode, 0, msg=result.stdout)
            self.assertIn("JWT ready for keyring storage", result.stdout)
            self.assertIn("Dry-run: nothing stored.", result.stdout)

    def test_secret_sync_requires_org(self):
        result = run_cmd([str(SCRIPTS / "papercut_secret_sync.sh")])
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("--org-id is required.", result.stdout)

    def test_keyring_init_help(self):
        result = run_cmd([str(SCRIPTS / "papercut_keyring_init.sh"), "--help"])
        self.assertEqual(result.returncode, 0, msg=result.stdout)
        self.assertIn("Initialize a persistent GNOME Secret Service collection", result.stdout)

    def test_root_helper_rejects_non_root(self):
        result = run_cmd(
            [
                str(SCRIPTS / "papercut_hive_token_sync_root.sh"),
                "--linux-user",
                "nobody",
                "--stdin",
            ]
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("must run as root", result.stdout)

    def test_secure_autodeploy_dry_run(self):
        with tempfile.TemporaryDirectory() as td:
            profile = self.make_extension_profile(Path(td))
            result = run_cmd(
                [
                    str(SCRIPTS / "install_hive_secure_autodeploy.sh"),
                    "--org-id",
                    "10196b04",
                    "--cloud-host",
                    "eu.hive.papercut.com",
                    "--linux-user",
                    os.environ.get("USER", "nicolas"),
                    "--bootstrap-from-extension",
                    "--profile-dir",
                    str(profile),
                    "--dry-run",
                ],
                timeout=120,
            )
            self.assertEqual(result.returncode, 0, msg=result.stdout)
            self.assertIn("Deployment complete.", result.stdout)

    def test_release_install_wrapper_dry_run(self):
        with tempfile.TemporaryDirectory() as td:
            profile = self.make_extension_profile(Path(td))
            result = run_cmd(
                [
                    str(RELEASE / "install.sh"),
                    "--org-id",
                    "10196b04",
                    "--linux-user",
                    os.environ.get("USER", "nicolas"),
                    "--profile-dir",
                    str(profile),
                    "--dry-run",
                ],
                timeout=120,
            )
            self.assertEqual(result.returncode, 0, msg=result.stdout)
            self.assertIn("Release install wrapper complete.", result.stdout)

    def test_release_finalize_requires_org(self):
        result = run_cmd([str(RELEASE / "finalize-session.sh")])
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("--org-id is required.", result.stdout)

    def test_release_finalize_help(self):
        result = run_cmd([str(RELEASE / "finalize-session.sh"), "--help"])
        self.assertEqual(result.returncode, 0, msg=result.stdout)
        self.assertIn("Finalize secure deployment from a normal user desktop session", result.stdout)

    def test_release_self_test_help(self):
        result = run_cmd([str(RELEASE / "self-test.sh"), "--help"])
        self.assertEqual(result.returncode, 0, msg=result.stdout)
        self.assertIn("Runs a lightweight post-install self-test", result.stdout)


if __name__ == "__main__":
    unittest.main()
