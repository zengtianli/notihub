"""SQLite online backup with integrity verification; backups outside the code tree."""
import datetime
import os
from pathlib import Path
import sqlite3

source = Path(os.environ["NOTIFHUB_DATABASE"])
folder = source.parent/"backups"
folder.mkdir(mode=0o700, exist_ok=True)
target = folder/(datetime.datetime.now().strftime("%Y%m%d-%H%M%S")+".sqlite")
with sqlite3.connect(source.as_uri()+"?mode=ro", uri=True) as src:
    with sqlite3.connect(target) as dst:
        src.backup(dst)
        assert dst.execute("PRAGMA integrity_check").fetchone()[0] == "ok"
target.chmod(0o600)
print("Verified SQLite backup:", target)
