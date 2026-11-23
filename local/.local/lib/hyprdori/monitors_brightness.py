"""Brightness, read from and set on the screen itself: the backlight, or DDC/CI."""

from __future__ import annotations

import re
import shutil

from monitors_base import run
from monitors_screens import is_internal

# ---------------------------------------------------------------- brightness


def backlight_device() -> str | None:
    out = (
        run(["brightnessctl", "-m", "-c", "backlight"])
        if shutil.which("brightnessctl")
        else ""
    )
    return out.split(",")[0] if out.strip() else None


def ddc_buses() -> dict[str, str]:
    """Map connector name (DP-1) to I2C bus number via `ddcutil detect`."""
    if not shutil.which("ddcutil"):
        return {}
    buses, bus = {}, None
    for line in run(["ddcutil", "detect", "--terse"]).splitlines():
        line = line.strip()
        if line.startswith("I2C bus:"):
            bus = line.rsplit("-", 1)[-1]
        elif line.startswith("DRM connector:") and bus:
            connector = line.split(":", 1)[1].strip()
            buses[re.sub(r"^card\d+-", "", connector)] = bus
    return buses


def brightness_get(live: list[dict]) -> dict:
    result = {}
    backlight = backlight_device()
    buses = None
    for m in live:
        if m.get("disabled"):
            continue
        name = m["name"]
        if is_internal(name) and backlight:
            f = run(["brightnessctl", "-m", "-d", backlight]).strip().split(",")
            result[name] = round(int(f[2]) * 100 / int(f[4])) if len(f) >= 5 else None
        else:
            if buses is None:
                buses = ddc_buses()
            bus = buses.get(name)
            value = None
            if bus:
                # VCP 10 C 50 100
                parts = run(
                    ["ddcutil", "--bus", bus, "getvcp", "10", "--terse"]
                ).split()
                if len(parts) >= 5 and parts[2] == "C":
                    value = round(int(parts[3]) * 100 / max(1, int(parts[4])))
            result[name] = value
    return result


def brightness_set(name: str, pct: int) -> None:
    pct = max(1, min(100, pct))
    backlight = backlight_device()
    if is_internal(name) and backlight:
        run(["brightnessctl", "-q", "-d", backlight, "s", f"{pct}%"])
        return
    bus = ddc_buses().get(name)
    if bus:
        # the screen's own scale: its maximum isn't always 100 (the Odyssey G50F's is 50)
        parts = run(["ddcutil", "--bus", bus, "getvcp", "10", "--terse"]).split()
        top = int(parts[4]) if len(parts) >= 5 and parts[2] == "C" else 100
        run(
            [
                "ddcutil",
                "--bus",
                bus,
                "setvcp",
                "10",
                str(max(1, round(pct * top / 100))),
                "--noverify",
            ]
        )
