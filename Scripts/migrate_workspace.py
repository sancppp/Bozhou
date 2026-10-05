#!/usr/bin/env python3
"""Copy the v1 workspace on install; never merge or replace user data."""
from contextlib import closing
from datetime import datetime
from pathlib import Path
import shutil
import sqlite3
import sys
import tempfile

TABLES = ("hosts", "identities", "snippets", "history", "pins", "settings")


def connect_readonly(database: Path):
    return sqlite3.connect(database.resolve().as_uri() + "?mode=ro", uri=True)


def has_data(root: Path) -> bool:
    if not root.exists():
        return False
    if root.is_symlink() or not root.is_dir():
        return True
    allowed = {"bozhou.sqlite", "bozhou.sqlite-wal", "bozhou.sqlite-shm",
               "known_hosts", "logs", "sessions"}
    if any(p.name not in allowed or p.is_symlink() for p in root.iterdir()):
        return True
    known_hosts = root / "known_hosts"
    if known_hosts.exists() and known_hosts.stat().st_size:
        return True
    database = root / "bozhou.sqlite"
    if database.exists():
        try:
            with closing(connect_readonly(database)) as connection:
                tables = {r[0] for r in connection.execute(
                    "SELECT name FROM sqlite_master WHERE type='table'")}
                if tables != set(TABLES):
                    return True
                return any(connection.execute(f"SELECT 1 FROM {table} LIMIT 1").fetchone()
                           for table in TABLES)
        except sqlite3.Error:
            return True
    return any((root / name).exists() for name in ("bozhou.sqlite-wal", "bozhou.sqlite-shm"))


def migrate(source: Path, destination: Path) -> bool:
    if not (source / "bozhou.sqlite").is_file() or not has_data(source):
        return False
    if has_data(destination):
        print(f"目标工作空间已有数据，保留原状；旧数据仍在：{source}")
        return False
    destination.parent.mkdir(parents=True, exist_ok=True)
    staging = Path(tempfile.mkdtemp(prefix=".bozhou-migrate-", dir=destination.parent))
    backup = None
    try:
        # SQLite backup includes committed WAL contents, unlike copying only the DB file.
        with closing(connect_readonly(source / "bozhou.sqlite")) as old:
            if old.execute("PRAGMA quick_check").fetchone() != ("ok",):
                raise ValueError("旧工作空间数据库校验失败，停止迁移")
            with closing(sqlite3.connect(staging / "bozhou.sqlite")) as new:
                old.backup(new)
        (staging / "bozhou.sqlite").chmod(0o600)
        for name in ("known_hosts", "logs"):
            item = source / name
            if item.is_symlink():
                raise ValueError(f"旧工作空间 {name} 是符号链接，停止迁移")
            if item.is_dir():
                shutil.copytree(item, staging / name)
            elif item.exists():
                shutil.copy2(item, staging / name)
        if (staging / "known_hosts").exists():
            (staging / "known_hosts").chmod(0o600)
        # Recheck before replacing the empty workspace. The installer requires app exit.
        if has_data(destination):
            raise ValueError("目标工作空间已出现数据，停止迁移")
        if destination.exists():
            stamp = datetime.now().strftime("%Y%m%d%H%M%S%f")
            backup = destination.with_name(f"{destination.name}.backup-{stamp}")
            destination.rename(backup)
        try:
            staging.rename(destination)
        except OSError:
            if backup is not None:
                backup.rename(destination)
            raise
        print(f"已迁移工作空间：{destination}；旧数据保留：{source}")
        if backup is not None:
            print(f"原空工作空间备份：{backup}")
        return True
    finally:
        if staging.exists():
            shutil.rmtree(staging)


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit("用法：migrate_workspace.py <旧目录> <新目录>（先退出泊舟）")
    migrate(Path(sys.argv[1]), Path(sys.argv[2]))
