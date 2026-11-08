#!/usr/bin/env python3
"""Data-preservation checks for the installation migration."""
from contextlib import closing, redirect_stdout
import io
import os
from pathlib import Path
import sqlite3
import subprocess
import tempfile
import unittest

from migrate_workspace import TABLES, migrate


def create_database(root: Path):
    root.mkdir()
    connection = sqlite3.connect(root / "bozhou.sqlite")
    connection.execute("PRAGMA journal_mode=WAL")
    for table in TABLES:
        connection.execute(f"CREATE TABLE {table} (id TEXT PRIMARY KEY, payload TEXT)")
    connection.commit()
    return connection


class MigrationTests(unittest.TestCase):
    def setUp(self):
        temporary = Path(__file__).resolve().parent.parent / ".runtime" / "tmp"
        temporary.mkdir(parents=True, exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(dir=temporary)
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.source, self.destination = self.root / "old", self.root / "new"
        self.output = redirect_stdout(io.StringIO())
        self.output.__enter__()
        self.addCleanup(self.output.__exit__, None, None, None)

    def test_wal_and_empty_destination_backup(self):
        with closing(create_database(self.source)) as old:
            old.execute("INSERT INTO pins VALUES ('pin', '中文收藏')")
            old.commit()
            (self.source / "known_hosts").write_text("test fingerprint\n")
            with closing(create_database(self.destination)):
                pass
            self.assertTrue(migrate(self.source, self.destination))
            with closing(sqlite3.connect(self.destination / "bozhou.sqlite")) as new:
                self.assertEqual(new.execute("SELECT payload FROM pins").fetchone(), ("中文收藏",))
            self.assertEqual(old.execute("SELECT count(*) FROM pins").fetchone(), (1,))
            self.assertEqual((self.destination / "known_hosts").read_text(), "test fingerprint\n")
            self.assertEqual(len(list(self.root.glob("new.backup-*"))), 1)
            self.assertFalse(migrate(self.source, self.destination))

    def test_existing_data_is_never_replaced(self):
        with closing(create_database(self.source)) as old:
            old.execute("INSERT INTO history VALUES ('old', 'old')")
            old.commit()
        for kind in ("settings", "known_hosts", "unknown"):
            with self.subTest(kind=kind):
                target = self.root / kind
                with closing(create_database(target)) as new:
                    if kind == "settings":
                        new.execute("INSERT INTO settings VALUES ('app', '{}')")
                        new.commit()
                    else:
                        (target / ("known_hosts" if kind == "known_hosts" else "unknown.txt")).write_text("keep")
                # SQLite readers may update WAL-index reader marks even in mode=ro.
                # The shared-memory index is transient; database/WAL and user files must stay intact.
                before = {p.name: p.read_bytes() for p in target.iterdir()
                          if p.is_file() and not p.name.endswith("-shm")}
                self.assertFalse(migrate(self.source, target))
                for name, contents in before.items():
                    self.assertEqual((target / name).read_bytes(), contents)

    def test_new_destination(self):
        with closing(create_database(self.source)) as old:
            old.execute("INSERT INTO hosts VALUES ('host', '{}')")
            old.commit()
        self.assertTrue(migrate(self.source, self.destination))
        self.assertFalse(list(self.root.glob("new.backup-*")))
        self.assertEqual(self.destination.stat().st_mode & 0o777, 0o700)

    def test_absent_or_empty_source(self):
        self.assertFalse(migrate(self.source, self.destination))
        with closing(create_database(self.source)):
            pass
        self.assertFalse(migrate(self.source, self.destination))
        self.assertFalse(self.destination.exists())

    def test_installer_defaults_to_system_applications(self):
        script = (Path(__file__).resolve().parent / "install.sh").read_text()
        self.assertIn('INSTALL_DIR="${1:-/Applications}"', script)
        self.assertNotIn("$HOME/Applications", script)

    def test_installer_verifies_the_requested_build_before_installing(self):
        project = Path(__file__).resolve().parent.parent
        executable = self.root / "codesign"
        executable.write_text(
            '#!/bin/sh\nprintf "%s\\n" "$@" > "$BOZHOU_TEST_CODESIGN_ARGS"\nexit 19\n'
        )
        executable.chmod(0o700)
        arguments = self.root / "codesign-arguments"
        destination = self.root / "Applications"
        for override in (None, str(self.root / "preview with spaces" / "泊舟.app")):
            with self.subTest(override=override):
                environment = dict(os.environ, PATH=f"{self.root}:{os.defpath}",
                                   BOZHOU_TEST_CODESIGN_ARGS=str(arguments))
                environment.pop("BOZHOU_APP_OUTPUT", None)
                if override is not None:
                    environment["BOZHOU_APP_OUTPUT"] = override
                result = subprocess.run(
                    ["/bin/bash", str(project / "Scripts/install.sh"), "--no-build", str(destination)],
                    env=environment, capture_output=True, text=True, check=False,
                )
                self.assertEqual(result.returncode, 19, result.stderr)
                self.assertEqual(arguments.read_text().splitlines(),
                                 ["--verify", "--deep", "--strict", override or str(project / "dist/泊舟.app")])
                self.assertFalse(destination.exists(), "The failing signature stub must prevent installation")


if __name__ == "__main__":
    unittest.main()
