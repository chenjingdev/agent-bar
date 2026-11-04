#!/usr/bin/env python3
"""Installer fixtures; no real application, credentials, or home overrides."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
import unittest


SCRIPTS = Path(__file__).resolve().parent
MOCK_COMMAND = r'''
import json
import os
from pathlib import Path
import shutil
import sys
import tempfile
import time

root = Path(os.environ["AGENTBAR_INSTALL_FIXTURE_DIR"])
command = Path(sys.argv[0]).name
args = sys.argv[1:]
with (root / "commands.jsonl").open("a") as output:
    output.write(json.dumps([command, args]) + "\n")

def flag(name):
    return (root / name).exists()

def confined(value):
    path = Path(value)
    if not path.is_absolute() or not path.is_relative_to(root):
        raise RuntimeError("Fixture command refused a path outside its temporary directory")
    return path

if command == "pgrep":
    sys.exit(2 if flag("process_check_error") else 0 if flag("active") else 1)
elif command == "codesign":
    target = confined(args[-1])
    rejected = (flag("bad_source_signature") and target == root / "build" / "AgentBar.app"
                or flag("bad_staged_signature") and target.name == "new.app"
                or flag("bad_installed_signature") and target == root / "Applications [fixture]" / "AgentBar.app")
    sys.exit(1 if rejected else 0)
elif command == "mkdir":
    for value in args:
        if not value.startswith("-"):
            confined(value).mkdir(parents=True, exist_ok=True)
elif command == "mktemp":
    template = confined(args[-1])
    print(tempfile.mkdtemp(prefix=template.name.rstrip("X"), dir=template.parent))
elif command == "ditto":
    source, destination = map(confined, args)
    if flag("copy_error"):
        destination.mkdir()
        (destination / "partial").write_text("incomplete")
        sys.exit(1)
    shutil.copytree(source, destination, symlinks=True)
    if flag("activate_after_copy"):
        (root / "active").touch()
elif command == "mv":
    source, destination = map(confined, args)
    if flag("placement_error") and source.name == "new.app":
        sys.exit(1)
    if flag("restore_error") and source.name == "previous.app":
        sys.exit(1)
    os.rename(source, destination)
    if flag("pause_after_old_move") and destination.name == "previous.app":
        (root / "old_app_moved").touch()
        deadline = time.monotonic() + 10
        while not flag("release_install"):
            if time.monotonic() > deadline:
                raise RuntimeError("Fixture installer was not released")
            time.sleep(0.01)
    if flag("placement_error_after_move") and source.name == "new.app":
        sys.exit(1)
elif command == "rm":
    for value in args:
        if not value.startswith("-"):
            path = confined(value)
            if path.is_dir() and not path.is_symlink():
                shutil.rmtree(path)
            else:
                path.unlink(missing_ok=True)
elif command == "swift":
    (root / "build_was_started").touch()
    sys.exit(99)
else:
    raise RuntimeError("Unexpected fixture command")
'''


class InstallTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="agentbar-install-test-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.source = self.root / "build" / "AgentBar.app"
        self.destination = self.root / "Applications [fixture]" / "AgentBar.app"
        self.make_app(self.source, "new")
        self.make_app(self.destination, "old")
        self.user_data = self.root / "user-data"
        for relative in (
            ".agentbar/multi-account-v1/accounts.json",
            ".agentbar/multi-account-v1/credentials/fixture/auth.json",
            "Library/Preferences/dev.chenjing.agent-bar.plist",
            "Library/Application Support/AgentBar/Backups/existing/manifest.json",
        ):
            path = self.user_data / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(b"fixture data, not a real credential")
        self.original_data = self.data_snapshot()
        self.commands = self.root / "mock-bin"
        self.commands.mkdir()
        mock = self.commands / "command.py"
        mock.write_text(f"#!{sys.executable}\n" + MOCK_COMMAND)
        mock.chmod(0o755)
        for name in ("pgrep", "codesign", "mkdir", "mktemp", "ditto", "mv", "rm", "swift"):
            (self.commands / name).symlink_to(mock)
        self.environment = dict(os.environ)
        self.environment["PATH"] = str(self.commands) + os.pathsep + self.environment.get("PATH", "")
        self.environment["AGENTBAR_INSTALL_FIXTURE_DIR"] = str(self.root)

    @staticmethod
    def make_app(path, version):
        executable = path / "Contents" / "MacOS" / "agent-bar"
        executable.parent.mkdir(parents=True)
        executable.write_text("#!/bin/sh\nexit 0\n")
        executable.chmod(0o755)
        (path / "Contents" / "version").write_text(version)

    def flag(self, name):
        (self.root / name).touch()

    def data_snapshot(self):
        return {str(path.relative_to(self.user_data)): path.read_bytes()
                for path in self.user_data.rglob("*") if path.is_file()}

    def install(self):
        return subprocess.run(["/bin/zsh", str(SCRIPTS / "install-app.sh"),
                               str(self.source), str(self.destination)],
                              env=self.environment, capture_output=True, text=True)

    def assert_version(self, expected):
        self.assertEqual((self.destination / "Contents" / "version").read_text(), expected)

    def assert_clean(self):
        self.assertEqual(list(self.destination.parent.glob(".AgentBar-install.*")), [])
        self.assertEqual(self.data_snapshot(), self.original_data)
        lock = self.destination.parent / ".AgentBar.install.lock"
        if lock.exists():
            self.assertEqual(lock.stat().st_size, 0)

    def test_success_replaces_only_app_and_creates_no_backups(self):
        result = self.install()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assert_version("new")
        self.assertEqual((self.source / "Contents" / "version").read_text(), "new")
        self.assert_clean()

    def test_first_install_creates_app_without_historical_backup(self):
        shutil.rmtree(self.destination)
        result = self.install()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assert_version("new")
        self.assert_clean()

    def test_first_install_verification_failure_removes_failed_app(self):
        shutil.rmtree(self.destination)
        self.flag("bad_installed_signature")
        self.assertNotEqual(self.install().returncode, 0)
        self.assertFalse(self.destination.exists())
        self.assert_clean()

    def test_running_app_changes_nothing(self):
        self.flag("active")
        result = self.install()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("still running", result.stderr)
        self.assert_version("old")
        self.assert_clean()
        commands = [json.loads(line)[0] for line in (self.root / "commands.jsonl").read_text().splitlines()]
        self.assertEqual(commands, ["pgrep"])

    def test_build_wrapper_checks_running_app_before_build(self):
        self.flag("active")
        result = subprocess.run(["/bin/zsh", str(SCRIPTS / "build-app.sh"), "--install"],
                                env=self.environment, capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("still running", result.stderr)
        self.assertFalse((self.root / "build_was_started").exists())
        self.assert_clean()

    def test_failed_process_check_stops_installation(self):
        self.flag("process_check_error")
        self.assertNotEqual(self.install().returncode, 0)
        self.assert_version("old")
        self.assert_clean()

    def test_app_started_during_staging_prevents_replacement(self):
        self.flag("activate_after_copy")
        result = self.install()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("still running", result.stderr)
        self.assert_version("old")
        self.assert_clean()

    def test_source_signature_failure_leaves_old_app_intact(self):
        self.flag("bad_source_signature")
        self.assertNotEqual(self.install().returncode, 0)
        self.assert_version("old")
        self.assert_clean()

    def test_staged_signature_failure_cleans_staging(self):
        self.flag("bad_staged_signature")
        self.assertNotEqual(self.install().returncode, 0)
        self.assert_version("old")
        self.assert_clean()
        (self.root / "bad_staged_signature").unlink()
        self.assertEqual(self.install().returncode, 0)
        self.assert_version("new")
        self.assert_clean()

    def test_copy_failure_cleans_partial_staging(self):
        self.flag("copy_error")
        self.assertNotEqual(self.install().returncode, 0)
        self.assert_version("old")
        self.assert_clean()

    def test_failed_placement_restores_previous_app(self):
        self.flag("placement_error")
        self.assertNotEqual(self.install().returncode, 0)
        self.assert_version("old")
        self.assert_clean()

    def test_placement_error_after_move_restores_previous_app(self):
        self.flag("placement_error_after_move")
        self.assertNotEqual(self.install().returncode, 0)
        self.assert_version("old")
        self.assert_clean()

    def test_installed_signature_failure_restores_previous_app(self):
        self.flag("bad_installed_signature")
        self.assertNotEqual(self.install().returncode, 0)
        self.assert_version("old")
        self.assert_clean()

    def test_failed_restore_keeps_previous_app_for_manual_recovery(self):
        self.flag("placement_error")
        self.flag("restore_error")
        result = self.install()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("preserved at:", result.stderr)
        staging = list(self.destination.parent.glob(".AgentBar-install.*"))
        self.assertEqual(len(staging), 1)
        self.assertEqual((staging[0] / "previous.app" / "Contents" / "version").read_text(), "old")
        self.assertEqual(self.data_snapshot(), self.original_data)

    def test_same_physical_source_and_destination_is_rejected(self):
        alias = self.root / "build-alias"
        alias.symlink_to(self.source.parent, target_is_directory=True)
        result = subprocess.run(["/bin/zsh", str(SCRIPTS / "install-app.sh"),
                                 str(alias / "AgentBar.app"), str(self.source)],
                                env=self.environment, capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("separate built", result.stderr)
        self.assertEqual((self.source / "Contents" / "version").read_text(), "new")
        self.assert_clean()

    def test_parent_alias_cannot_hide_a_running_native_app(self):
        executable = self.destination / "Contents" / "MacOS" / "agent-bar"
        # Copy bytes, not protected system-file flags from /bin/sleep.
        shutil.copyfile("/bin/sleep", executable)
        executable.chmod(0o755)
        alias = self.root / "applications-alias"
        alias.symlink_to(self.destination.parent, target_is_directory=True)
        # Use the real process lookup for this test, not the fixture pgrep.
        (self.commands / "pgrep").unlink()
        (self.commands / "pgrep").symlink_to("/usr/bin/pgrep")
        owned_process = subprocess.Popen([str(executable), "30"])
        try:
            deadline = time.monotonic() + 3
            while True:
                matches = subprocess.run(["/usr/bin/pgrep", "-x", "agent-bar"],
                                         capture_output=True, text=True)
                if str(owned_process.pid) in matches.stdout.splitlines():
                    break
                self.assertLess(time.monotonic(), deadline, "Native fixture was not detected")
                time.sleep(0.01)
            result = subprocess.run(["/bin/zsh", str(SCRIPTS / "install-app.sh"),
                                     "--check-running", str(alias / "AgentBar.app")],
                                    env=self.environment, capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("still running", result.stderr)
            self.assert_version("old")
            self.assert_clean()
        finally:
            # Only terminate the process created by this fixture.
            owned_process.terminate()
            owned_process.wait(timeout=3)

    def test_concurrent_installer_is_blocked_until_first_finishes(self):
        self.flag("pause_after_old_move")
        holder = subprocess.Popen(["/bin/zsh", str(SCRIPTS / "install-app.sh"),
                                   str(self.source), str(self.destination)],
                                  env=self.environment, stdout=subprocess.PIPE,
                                  stderr=subprocess.PIPE, text=True)
        try:
            deadline = time.monotonic() + 3
            while not (self.root / "old_app_moved").exists():
                self.assertIsNone(holder.poll(), "First installer exited before holding the old app")
                self.assertLess(time.monotonic(), deadline, "First installer did not reach replacement")
                time.sleep(0.01)
            lock = self.destination.parent / ".AgentBar.install.lock"
            original_inode = lock.stat().st_ino
            contender = self.install()
            self.assertNotEqual(contender.returncode, 0)
            self.assertIn("Another AgentBar installer", contender.stderr)
            self.assertFalse(self.destination.exists())
            self.assertIsNone(holder.poll())
            (self.root / "release_install").touch()
            stdout, stderr = holder.communicate(timeout=5)
            self.assertEqual(holder.returncode, 0, stdout + stderr)
            self.assert_version("new")
            self.assert_clean()
            # A subsequent process can acquire the same persistent lock inode.
            self.assertEqual(self.install().returncode, 0)
            self.assertEqual(lock.stat().st_ino, original_inode)
            self.assert_clean()
        finally:
            (self.root / "release_install").touch()
            if holder.poll() is None:
                holder.communicate(timeout=5)


if __name__ == "__main__":
    unittest.main(verbosity=2)
