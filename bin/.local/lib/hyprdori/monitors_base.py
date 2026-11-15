"""What every part of hyprdori-monitors uses: its files and limits, running a command, asking
Hyprland, the log."""

from __future__ import annotations

import json
import os
import subprocess
import time
from pathlib import Path

HOME = Path.home()
PROFILES_FILE = HOME / ".config/hypr/monitors.json"
GENERATED_FILE = HOME / ".config/hypr/configs/generated/monitors.lua"
GAMEMODE = Path(os.environ.get("XDG_RUNTIME_DIR", "/tmp")) / "hyprdori-mode"
GREETER_LAYOUT = Path("/var/lib/hyprdori/monitors.conf")  # only after sddm/install.sh
LOG_FILE = HOME / ".cache/hypr-monitors.log"
LOCK_FILE = Path(os.environ.get("XDG_RUNTIME_DIR", "/tmp")) / "hypr-monitors.lock"
LAST_RUN_FILE = LOCK_FILE.with_name("hypr-monitors.last")
LAST_RUN_WINDOW = 10.0  # s; the same monitors again this soon need nothing done
# Hyprland's rule for monitors no profile names: preferred mode, automatic position and scale
FALLBACK_RULE = 'hl.monitor({ output = "", mode = "preferred", position = "auto", scale = "auto", supports_hdr = -1 })'
GAMEMODE_SCRIPT = HOME / ".local/bin/hyprdori-mode"
THEME_SET = HOME / ".local/bin/hyprdori-theme-set"

INTERNAL_PREFIXES = ("eDP", "LVDS", "DSI")
WORKSPACES = 10
MAX_PER_MONITOR = 5
PROFILE_VERSION = 2

VRR_MODES = (0, 1, 2, 3)  # off, always, fullscreen, games and video
COLOR_MODES = ("srgb", "edid")

# Text size anchors: 12 px is the shell's body text, a 9 pt kitty font and an
# 11 pt GTK font
TEXT_SIZE_DEFAULT = 12  # px, for a setup with no saved size
TEXT_SIZE_BASE = 12
KITTY_FONT_DEFAULT = 9  # pt at 12 px
KITTY_TEXT_SIZE_FILE = HOME / ".config/kitty/text-size.conf"

# Descriptions shared by several connected monitors (same model, no serial);
# those are told apart by port instead
DUPLICATES: set[str] = set()


def run(cmd: list[str], *, check: bool = False) -> str:
    out = subprocess.run(
        cmd, check=check, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True
    )
    return out.stdout


def hypr_json(what: str) -> list:
    try:
        return json.loads(run(["hyprctl", what, "all", "-j"]) or "[]")
    except json.JSONDecodeError:
        return []


def is_placeholder(name: str) -> bool:
    """Outputs Hyprland makes up: FALLBACK when no real monitor is on (e.g. the laptop's
    screen turned off and the external ones unplugged), HEADLESS-N for virtual ones.
    They're never part of a profile, or a setup with the laptop's screen off would be saved.
    """
    return name == "FALLBACK" or name.startswith("HEADLESS-")


def live_monitors() -> list[dict]:
    """The connected real monitors, enabled or not."""
    return [m for m in hypr_json("monitors") if not is_placeholder(m.get("name", ""))]


def active_workspace() -> int | None:
    try:
        return json.loads(run(["hyprctl", "-j", "activeworkspace"]) or "{}").get("id")
    except (json.JSONDecodeError, AttributeError):
        return None


def log(message: str) -> None:
    try:
        LOG_FILE.parent.mkdir(parents=True, exist_ok=True)
        lines = LOG_FILE.read_text().splitlines()[-200:] if LOG_FILE.exists() else []
        lines.append(time.strftime("%Y-%m-%d %H:%M:%S ") + message)
        LOG_FILE.write_text("\n".join(lines) + "\n")
    except OSError:
        pass
