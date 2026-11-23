"""The Chromium-based browsers Hyprdori knows (the table in ./browsers), the installed ones, and
which is the default."""

import shutil
import subprocess
from pathlib import Path
from typing import NamedTuple

TABLE = Path(__file__).with_name("browsers")


class Browser(NamedTuple):
    command: str
    entry: str
    process: str
    app_class: str
    policy: str  # "" when the theme's color isn't set for it


def known() -> list[Browser]:
    rows = []
    for line in TABLE.read_text().splitlines():
        fields = line.split("#")[0].split()
        if len(fields) == 5:
            rows.append(Browser(*fields[:4], "" if fields[4] == "-" else fields[4]))
    return rows


def default_entry() -> str:
    """The default browser's launcher entry (chromium.desktop), or "" when none is set."""
    if not shutil.which("xdg-settings"):
        return ""
    out = subprocess.run(["xdg-settings", "get", "default-web-browser"], capture_output=True, text=True)
    return out.stdout.strip()


def installed(default_first: bool = True) -> list[Browser]:
    """The installed ones, one per browser (its first command found); the default first, which
    costs a call to xdg-settings."""
    found, entries = [], set()
    for browser in known():
        if browser.entry not in entries and shutil.which(browser.command):
            found.append(browser)
            entries.add(browser.entry)
    if not default_first:
        return found
    default = default_entry()
    return sorted(found, key=lambda browser: browser.entry != default)
