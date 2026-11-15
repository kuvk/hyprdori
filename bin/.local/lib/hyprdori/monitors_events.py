"""Monitors plugged in or out, the login, and the lid: the profile applied again, once things
have settled and the screen is unlocked."""

from __future__ import annotations

import fcntl
import os
import time

from monitors_apply import apply, lid_closed, state
from monitors_base import (
    DUPLICATES,
    LAST_RUN_FILE,
    LAST_RUN_WINDOW,
    LOCK_FILE,
    active_workspace,
    hypr_json,
    live_monitors,
    log,
    run,
)
from monitors_profiles import current_profile, load_profiles, profile_key
from monitors_screens import ident


def settle(timeout: float = 8.0) -> list[dict]:
    """Wait until the set of monitors stops changing (a dock, or a dGPU
    output that shows up a few seconds into the session)."""
    live, key, stable = [], None, 0
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        now = live_monitors()
        now_key = " + ".join(sorted(m["name"] for m in now))
        stable = stable + 1 if now and now_key == key else 0
        live, key = now, now_key
        if stable >= 3:  # unchanged for 1.5 s
            break
        time.sleep(0.5)
    return live


def wake_dark_monitors(data: dict, live: list[dict]) -> None:
    """A monitor that should be on but is disabled or has DPMS off after the
    reload (seen right after login) gets one more reload and DPMS on. Only then: a
    needless DPMS on forces another modeset, which blanks the screens for a moment."""
    _, profile = current_profile(data, live)
    wanted = {mid for mid, mon in profile["monitors"].items() if mon["enabled"]}
    now = live_monitors()
    dark = [
        m["name"]
        for m in now
        if ident(m) in wanted and (m.get("disabled") or not m.get("dpmsStatus", True))
    ]
    if dark:
        log(f"monitors still dark after applying: {', '.join(dark)}; reloading again")
        run(["hyprctl", "reload"])
        time.sleep(1)
        run(["hyprctl", "dispatch", 'hl.dsp.dpms({ action = "on" })'])


def last_run_id(key: str) -> str:
    return f"{os.environ.get('HYPRLAND_INSTANCE_SIGNATURE', '')}\n{key}"


def handled_just_now(key: str) -> bool:
    try:
        return (
            LAST_RUN_FILE.read_text() == last_run_id(key)
            and time.time() - LAST_RUN_FILE.stat().st_mtime < LAST_RUN_WINDOW
        )
    except OSError:
        return False


def locked() -> bool:
    """The session is locked: Hyprland lists a held lock (LOCK) among the reasons a monitor
    can't go solitary, also while the lock screen is restarting after a crash."""
    return any(
        "LOCK" in (m.get("solitaryBlockedBy") or []) for m in hypr_json("monitors")
    )


def wait_for_unlock() -> None:
    """No reload under the lock screen: monitors come back from sleep one by one, and a
    reload with half of them crashed the lock screen. Outputs added meanwhile use the
    catch-all monitor rule; the profile is applied once unlocked."""
    if not locked():
        return
    log("screen locked: waiting to apply the monitor profile until it's unlocked")
    while locked():
        time.sleep(2)
    time.sleep(1)


def hotplug(startup: bool = False) -> int:
    """Monitors were plugged in or out (or the session just started): switch
    to the saved profile for the connected set. Waits for the set to settle;
    one run at a time, and runs again if the set changed meanwhile."""
    LOCK_FILE.parent.mkdir(parents=True, exist_ok=True)
    with open(LOCK_FILE, "w") as lock:
        try:
            # at login, wait for a hotplug run instead of skipping
            fcntl.flock(
                lock, fcntl.LOCK_EX if startup else fcntl.LOCK_EX | fcntl.LOCK_NB
            )
        except BlockingIOError:
            return 0  # another run is handling it
        wait_for_unlock()
        live = settle()
        for _ in range(5):
            if locked():
                wait_for_unlock()
                live = settle()
            if not live:
                return 1
            DUPLICATES.clear()
            descs = [(m.get("description") or "").strip() for m in live]
            DUPLICATES.update(d for d in descs if d and descs.count(d) > 1)
            key = profile_key(live)
            # Login fires both the monitor.added event and `startup`: one run does the work
            if handled_just_now(key):
                return 0
            state = ", ".join(
                f"{m['name']}{' disabled' if m.get('disabled') else ''}{' dpms-off' if not m.get('dpmsStatus', True) else ''}"
                for m in live
            )
            log(
                f"{'startup' if startup else 'hotplug'}: applying profile '{key}' ({state})"
            )
            data = load_profiles()
            apply(data, live)
            # start from the first workspace on the new layout (at login autostart already did)
            if active_workspace() != 1:
                run(["hyprctl", "dispatch", "hl.dsp.focus({ workspace = 1 })"])
            time.sleep(1)
            again = settle(4) or live
            if profile_key(again) == key:
                wake_dark_monitors(data, again)
                LAST_RUN_FILE.write_text(last_run_id(key))
                break
            live = again
    return 0


def lid() -> int:
    """The lid opened or closed (bindings.lua): apply the profile again, which turns the
    laptop's screen off or back on (with_clamshell). Not under the lock screen."""
    with open(LOCK_FILE, "w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        wait_for_unlock()
        live = settle(3)
        if not live:
            return 1
        DUPLICATES.clear()
        descs = [(m.get("description") or "").strip() for m in live]
        DUPLICATES.update(d for d in descs if d and descs.count(d) > 1)
        log(
            f"lid {'closed' if lid_closed() else 'open'}: applying profile '{profile_key(live)}'"
        )
        apply(load_profiles(), live)
    return 0
