"""The profiles in monitors.json: one per set of connected monitors, made from the live layout
the first time a set is seen, with the workspaces split across the monitors."""

from __future__ import annotations

import json

from monitors_base import (
    MAX_PER_MONITOR,
    PROFILE_VERSION,
    PROFILES_FILE,
    TEXT_SIZE_BASE,
    TEXT_SIZE_DEFAULT,
    WORKSPACES,
    is_placeholder,
)
from monitors_screens import ident, is_internal, logical_size, mode_str, preferred_mode

# ---------------------------------------------------------------- profiles


def load_profiles() -> dict:
    try:
        data = json.loads(PROFILES_FILE.read_text())
    except (FileNotFoundError, json.JSONDecodeError):
        data = {}
    # Each profile keeps its own text size; the top-level one is the connected setup's, for
    # what reads it (the shell's Theme.qml, hyprdori-theme-set)
    if "text_size" not in data:
        scale = data.pop("text_scale", None)
        data["text_size"] = (
            round(TEXT_SIZE_BASE * float(scale)) if scale else TEXT_SIZE_DEFAULT
        )
    data.setdefault("profiles", {})
    # Profiles saved with a placeholder output (older versions did); dropped at the next save
    data["profiles"] = {
        key: profile
        for key, profile in data["profiles"].items()
        if not any(is_placeholder(part) for part in key.split(" + "))
    }
    return data


def save_profiles(data: dict) -> None:
    PROFILES_FILE.parent.mkdir(parents=True, exist_ok=True)
    tmp = PROFILES_FILE.with_suffix(".tmp")
    tmp.write_text(json.dumps(data, indent=2) + "\n")
    tmp.replace(PROFILES_FILE)


def profile_key(live: list[dict]) -> str:
    return " + ".join(sorted(ident(m) for m in live))


def default_profile(live: list[dict]) -> dict:
    """Start from what Hyprland shows now, then split workspaces."""
    monitors = {}
    for m in live:
        enabled = not m.get("disabled", False)
        monitors[ident(m)] = {
            "enabled": enabled,
            "mode": (
                mode_str(m["width"], m["height"], m["refreshRate"])
                if enabled
                else preferred_mode(m)
            ),
            "x": m.get("x", 0),
            "y": m.get("y", 0),
            "scale": round(float(m.get("scale", 1)), 6),
            "transform": m.get("transform", 0),
        }
    enable_if_all_off(monitors, live)

    profile = {
        "version": PROFILE_VERSION,
        "monitors": monitors,
        "primary": default_primary(live, monitors),
    }
    profile["workspaces"] = default_workspaces(profile, live)
    return profile


def enable_if_all_off(monitors: dict, live: list[dict]) -> bool:
    """A setup is never saved or applied with every connected monitor off (a laptop screen
    off from the last setup, alone at login): turn them all on, side by side. True if
    anything changed."""
    connected = [m for m in live if ident(m) in monitors]
    if not connected or any(monitors[ident(m)]["enabled"] for m in connected):
        return False
    x = 0
    for m in sorted(connected, key=lambda m: (is_internal(m["name"]), m["name"])):
        mon = monitors[ident(m)]
        mon.update(enabled=True, x=x, y=0)
        x += round(logical_size(mon)[0])
    return True


def default_primary(live: list[dict], monitors: dict) -> str:
    """The leftmost external monitor, or the internal one when alone."""
    enabled = [m for m in live if monitors[ident(m)]["enabled"]] or live
    order = sorted(
        enabled, key=lambda m: (is_internal(m["name"]), monitors[ident(m)]["x"])
    )
    return ident(order[0]) if order else ""


def default_workspaces(profile: dict, live: list[dict]) -> dict[str, str]:
    """Primary first, then left to right; at most 5 each (1 monitor: 1-5,
    2: 1-5 / 6-10, 3: 1-3 / 4-6 / 7-9)."""
    mons = profile["monitors"]
    enabled = [ident(m) for m in live if mons.get(ident(m), {}).get("enabled")]
    if not enabled:
        return {}
    primary = profile.get("primary")
    order = sorted(
        enabled, key=lambda mid: (mid != primary, mons[mid]["x"], mons[mid]["y"])
    )
    per = min(MAX_PER_MONITOR, WORKSPACES // len(order))
    workspaces, ws = {}, 1
    for mid in order:
        for _ in range(per):
            workspaces[str(ws)] = mid
            ws += 1
    return workspaces


def current_profile(
    data: dict, live: list[dict], *, save: bool = True
) -> tuple[str, dict]:
    """The profile for the connected monitors, made from the live layout the first time.
    With save=False (Quickshell only showing it) a new or updated profile isn't written:
    it's saved when it's applied."""
    key = profile_key(live)
    profile = data["profiles"].get(key)
    changed = profile is None
    if profile is None:
        profile = default_profile(live)
        data["profiles"][key] = profile
    # Monitors seen for the first time inside a known setup cannot happen
    # (the key would differ), but keep the profile complete anyway
    for m in live:
        profile["monitors"].setdefault(
            ident(m), default_profile([m])["monitors"][ident(m)]
        )
    if enable_if_all_off(profile["monitors"], live):
        changed = True
        if not effective_workspaces(profile, live):
            profile["workspaces"] = default_workspaces(profile, live)
    # Profiles from the first version gave a lone monitor all 10 workspaces;
    # redo their workspaces with the current defaults, keep the layout
    if profile.get("version") != PROFILE_VERSION:
        profile["version"] = PROFILE_VERSION
        profile["primary"] = default_primary(live, profile["monitors"])
        profile["workspaces"] = default_workspaces(profile, live)
        changed = True
    if changed and save:
        save_profiles(data)
    return key, profile


def effective_workspaces(profile: dict, live: list[dict]) -> dict[str, str]:
    """Rules only for enabled monitors. A disabled monitor's workspaces get no
    rule (Hyprland opens them on the focused monitor) and come back when it's re-enabled.
    """
    connected = {ident(m) for m in live}
    enabled = {
        mid
        for mid, mon in profile["monitors"].items()
        if mon["enabled"] and mid in connected
    }
    return {ws: mid for ws, mid in profile["workspaces"].items() if mid in enabled}
