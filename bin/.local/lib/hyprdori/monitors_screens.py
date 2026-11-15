"""A monitor as Hyprland and its EDID describe it: what identifies it, its modes, sizes and scales."""

from __future__ import annotations

import re
from pathlib import Path

from monitors_base import DUPLICATES, INTERNAL_PREFIXES


def edid_bits(name: str) -> int:
    """The most bits per color the monitor on connector NAME takes, from its EDID: the
    header's color depth (EDID 1.4), else the HDMI block's deep color flags (EDID 1.3
    HDMI screens). 8 when it says nothing."""
    bits = 8
    for path in Path("/sys/class/drm").glob(f"card*-{name}/edid"):
        try:
            edid = path.read_bytes()
        except OSError:
            continue
        if len(edid) < 128:
            continue
        # byte 20: a digital input's color depth in bits 6-4 (EDID 1.4)
        if edid[18] == 1 and edid[19] >= 4 and edid[20] & 0x80:
            bits = max(
                bits,
                {1: 6, 2: 8, 3: 10, 4: 12, 5: 14, 6: 16}.get((edid[20] >> 4) & 7, 8),
            )
        # CTA extensions: the HDMI vendor block (OUI 00-0C-03); byte 6 bit 4 is DC_30bit,
        # bit 5 DC_36bit
        for start in range(128, len(edid) - 127, 128):
            block = edid[start : start + 128]
            if block[0] != 0x02:
                continue
            i, end = 4, min(block[2], 127)
            while i < end:
                tag, length = block[i] >> 5, block[i] & 0x1F
                data = block[i + 1 : i + 1 + length]
                if tag == 3 and len(data) >= 6 and bytes(data[:3]) == b"\x03\x0c\x00":
                    if data[5] & 0x20:
                        bits = max(bits, 12)
                    elif data[5] & 0x10:
                        bits = max(bits, 10)
                i += 1 + length
    return bits


def max_bitdepth(m: dict) -> int:
    """8 or 10: what Hyprland can send this monitor (it does 8 and 10), from its EDID."""
    return 10 if edid_bits(m["name"]) >= 10 else 8


def is_internal(name: str) -> bool:
    return name.startswith(INTERNAL_PREFIXES)


def ident(m: dict) -> str:
    """Stable identity: the EDID description, falling back to the port name."""
    desc = (m.get("description") or "").strip()
    return desc if desc and desc not in DUPLICATES else m["name"]


def selector(mon_id: str, live: dict[str, dict]) -> str:
    m = live.get(mon_id)
    if m and ident(m) != m["name"]:
        return "desc:" + m["description"].strip()
    return mon_id


def mode_str(width: int, height: int, refresh: float) -> str:
    return f"{width}x{height}@{refresh:.2f}"


def parse_mode(mode: str) -> tuple[int, int]:
    m = re.match(r"(\d+)x(\d+)", mode)
    return (int(m.group(1)), int(m.group(2))) if m else (1920, 1080)


def logical_size(mon: dict) -> tuple[float, float]:
    w, h = parse_mode(mon["mode"])
    if mon.get("transform", 0) % 2 == 1:
        w, h = h, w
    scale = float(mon.get("scale", 1)) or 1
    return w / scale, h / scale


def available_modes(m: dict) -> list[str]:
    modes = []
    for raw in m.get("availableModes", []):
        mm = re.match(r"(\d+)x(\d+)@([\d.]+)", raw)
        if mm:
            s = mode_str(int(mm.group(1)), int(mm.group(2)), float(mm.group(3)))
            if s not in modes:
                modes.append(s)
    return modes


def clean_scale(scale: float, width: int, height: int) -> float:
    """Hyprland only accepts scales that divide the mode into whole logical
    pixels, in 1/120 steps. Round up to the nearest such scale."""
    from math import gcd

    g = gcd(width * 120, height * 120)
    k = max(1, min(g, int(scale * 120 + 0.5)))
    while g % k:
        k += 1
    return round(k / 120, 6)


def preferred_mode(m: dict) -> str:
    """The monitor's own preferred mode, which Hyprland lists first (as `mode = "preferred"`
    picks it), not the largest: a 1440p@144 screen that also takes 4K@60 keeps 1440p@144.
    Displays changes it, and the profile keeps the choice."""
    modes = available_modes(m)
    if not modes:
        return mode_str(
            m.get("width", 1920), m.get("height", 1080), m.get("refreshRate", 60)
        )
    return modes[0]
