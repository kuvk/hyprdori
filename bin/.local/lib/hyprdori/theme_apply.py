"""A theme on the running system: what shows at once, the apps told to reload in the
background, cursor, fonts, GTK, the browsers, corners, and the notification."""

import json
import os
import re
import shutil
import signal
import subprocess
from pathlib import Path

from theme_colors import CURRENT_DIR, HOME, current_theme, notify, run_quiet
from theme_render import EXTRA_DESTINATIONS, SPICETIFY_DIR, generate, write_if_changed


def hypr_running() -> bool:
    return (
        bool(os.environ.get("HYPRLAND_INSTANCE_SIGNATURE"))
        and shutil.which("hyprctl") is not None
    )


def apply_cursor(strings: dict) -> None:
    interface = "org.gnome.desktop.interface"
    run_quiet(["gsettings", "set", interface, "cursor-theme", strings["cursor_theme"]])
    run_quiet(["gsettings", "set", interface, "cursor-size", strings["cursor_size"]])
    if hypr_running():
        run_quiet(
            ["hyprctl", "setcursor", strings["cursor_theme"], strings["cursor_size"]]
        )
    set_xwayland_cursor(strings["cursor_theme"], strings["cursor_size"])


def set_xwayland_cursor(theme: str, size: str) -> None:
    """XWayland's default arrow, for X11 apps that set no cursor of their own (Parsec).
    Hyprland sets it once, when XWayland starts, so it doesn't follow `hyprctl setcursor`.
    """
    if not os.environ.get("DISPLAY") or not shutil.which("xsetroot"):
        return
    env = {**os.environ, "XCURSOR_THEME": theme, "XCURSOR_SIZE": size}
    subprocess.run(
        ["xsetroot", "-cursor_name", "left_ptr"],
        env=env,
        check=False,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )


def apply_fonts(strings: dict) -> None:
    interface = "org.gnome.desktop.interface"
    pt = strings["gtk_font_pt"]
    run_quiet(
        ["gsettings", "set", interface, "font-name", f"{strings['text_font']} {pt}"]
    )
    run_quiet(
        [
            "gsettings",
            "set",
            interface,
            "document-font-name",
            f"{strings['text_font']} {pt}",
        ]
    )
    run_quiet(
        [
            "gsettings",
            "set",
            interface,
            "monospace-font-name",
            f"{strings['nerd_font']} {pt}",
        ]
    )
    run_quiet(["gsettings", "set", interface, "text-scaling-factor", "1.0"])
    run_quiet(["gsettings", "set", interface, "font-hinting", strings["font_hinting"]])
    run_quiet(
        [
            "gsettings",
            "set",
            interface,
            "font-antialiasing",
            strings["font_antialiasing"],
        ]
    )
    run_quiet(["gsettings", "set", interface, "font-rgba-order", "rgb"])


def apply_window_buttons(strings: dict) -> None:
    run_quiet(
        [
            "gsettings",
            "set",
            "org.gnome.desktop.wm.preferences",
            "button-layout",
            strings["decoration_layout"],
        ]
    )


def set_gtk_theme(strings: dict) -> None:
    """Wayland GTK apps read these; settings.ini (rendered above) is for XWayland ones."""
    interface = "org.gnome.desktop.interface"
    run_quiet(["gsettings", "set", interface, "gtk-theme", strings["gtk_theme"]])
    run_quiet(["gsettings", "set", interface, "icon-theme", strings["icon_theme"]])
    apply_cursor(strings)
    apply_fonts(strings)
    apply_window_buttons(strings)
    run_quiet(
        ["gsettings", "set", interface, "color-scheme", f"prefer-{strings['mode']}"]
    )


def reload_visible(theme: dict) -> None:
    """What a theme switch shows at once: the shell, Hyprland's borders and kitty. The
    animated switch (the shell's SwitchFx) waits for these and the wallpaper, then reveals.
    """
    # quickshell and neovim watch their generated files; poke quickshell anyway
    # in case the watch was lost when the file was replaced
    run_quiet(["qs", "ipc", "call", "theme", "reload"])

    if hypr_running():
        # The borders from the generated theme.lua (hyprland.lua.tpl), in every mode
        run_quiet(
            [
                "hyprctl",
                "eval",
                "package.loaded['configs.generated.theme'] = nil; local ok, t = pcall(require, 'configs.generated.theme'); "
                "if ok then hl.config({ general = { col = { active_border = t.active_border, inactive_border = t.inactive_border } } }) end",
            ]
        )

    run_quiet(["pkill", "-USR1", "-x", "kitty"])


def spicetify_follows() -> bool:
    """Spicetify set up with the "hyprdori" theme (hyprdori-spicetify)."""
    try:
        config = (SPICETIFY_DIR / "config-xpui.ini").read_text()
    except OSError:
        return False
    return (
        shutil.which("spicetify") is not None
        and re.search(r"^current_theme\s*=\s*hyprdori\s*$", config, re.M) is not None
    )


def bat_cache_stale() -> bool:
    """bat's theme cache missing, or older than the theme file it should hold."""
    theme_file = EXTRA_DESTINATIONS["bat.tmTheme"]
    cache = Path(os.environ.get("XDG_CACHE_HOME", HOME / ".cache")) / "bat/themes.bin"
    try:
        return not cache.exists() or cache.stat().st_mtime < theme_file.stat().st_mtime
    except OSError:
        return False


def reload_apps(theme: dict) -> None:
    """The rest, after the switch is shown (in the background): the other apps, GTK,
    browsers and the theme's own wallpaper."""
    colors, strings = theme["colors"], theme["strings"]

    run_quiet(["pkill", "-USR2", "-x", "btop"])
    run_quiet(["pkill", "-USR2", "-x", "cava"])  # reload colors
    run_quiet(["pkill", "-USR1", "-x", "swayimg"])  # re-reads current/swayimg.lua
    # bat reads themes from a cache that must be rebuilt: after the theme file changed, and
    # whenever the cache is missing or older than it (a fresh install, a cleared cache), so a
    # build that didn't happen is made up at the next run (login)
    if shutil.which("bat") and (
        "bat.tmTheme" in theme.get("changed", ()) or bat_cache_stale()
    ):
        run_quiet(["bat", "cache", "--build"])
    if "yazi-theme.toml" in theme.get("changed", ()):
        restart_yazi()
    # Spotify: the new colors into its files (a second); an open Spotify shows them when restarted
    if {"spicetify-color.ini", "spicetify-user.css"} & theme.get(
        "changed", set()
    ) and spicetify_follows():
        run_quiet(["spicetify", "-n", "-q", "refresh"])
    redraw_prompts()
    if (
        shutil.which("tmux")
        and subprocess.run(["tmux", "info"], capture_output=True).returncode == 0
    ):
        run_quiet(["tmux", "source-file", str(HOME / ".tmux.conf")])
    # a running cliamp re-reads the theme file when told to switch to it
    if (
        "cliamp.toml" in theme.get("changed", ())
        and shutil.which("cliamp")
        and (HOME / ".config/cliamp/cliamp.sock").exists()
    ):
        run_quiet(["cliamp", "theme", "system"])

    # file dialogs: the portal reads gtk.css only when it starts
    if "gtk.css" in theme.get("changed", ()):
        run_quiet(
            ["systemctl", "--user", "try-restart", "xdg-desktop-portal-gtk.service"]
        )

    browsers(colors["background"])

    set_gtk_theme(strings)

    wallpaper = strings.get("wallpaper")
    if wallpaper and hypr_running():
        path = Path(os.path.expanduser(wallpaper))
        if not path.is_absolute():
            path = theme["dir"] / path
        if path.exists():
            out = subprocess.run(
                ["hyprctl", "monitors", "-j"], capture_output=True, text=True
            )
            try:
                monitors = [m["name"] for m in json.loads(out.stdout)]
            except (json.JSONDecodeError, KeyError, TypeError):
                monitors = []
            for monitor in monitors:
                run_quiet(
                    ["hyprctl", "hyprpaper", "wallpaper", f"{monitor},{path},cover"]
                )


def redraw_prompts() -> None:
    """Open zsh shells redraw their starship prompt in the new colors. Only
    shells that registered themselves (.zshrc, they trap USR1) are signalled:
    USR1 would end any other process."""
    runtime = Path(os.environ.get("XDG_RUNTIME_DIR", "/tmp")) / "zsh-prompt"
    if not runtime.is_dir():
        return
    for entry in runtime.iterdir():
        try:
            pid = int(entry.name)
            with open(f"/proc/{pid}/comm") as f:
                if f.read().strip() != "zsh":
                    raise ProcessLookupError
            os.kill(pid, signal.SIGUSR1)
        except (ValueError, OSError):
            entry.unlink(missing_ok=True)  # gone, or the pid was reused


def restart_yazi() -> None:
    """yazi can't reload its theme: every yazi started by hyprdori-yazi-live is told
    to quit (it writes its folder) and the script reopens it right there."""
    runtime = Path(os.environ.get("XDG_RUNTIME_DIR", "/tmp")) / "yazi-live"
    if not shutil.which("ya") or not runtime.is_dir():
        return
    for client in runtime.glob("*.client"):
        pid = client.stem
        try:
            os.kill(int(pid), 0)
        except (ValueError, ProcessLookupError):
            client.unlink(missing_ok=True)  # left over from a crash
            continue
        except PermissionError:
            continue
        (runtime / f"{pid}.restart").touch()
        run_quiet(["ya", "emit-to", pid, "quit"])


BROWSER_HELPER = "/usr/local/bin/browser-theme-policy"


def browsers(color: str) -> None:
    """Chromium/Brave theme color via managed policy (hyprdori-browser-theme-setup).
    Does nothing until that one-time setup has been run."""
    if not Path(BROWSER_HELPER).exists() or not shutil.which("sudo"):
        return
    result = subprocess.run(
        ["sudo", "-n", BROWSER_HELPER, color[1:]],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    if result.returncode != 0:
        return
    # Running browsers pick the policy up without a restart
    for proc, binary in (("chromium", "chromium"), ("brave", "brave")):
        if (
            shutil.which(binary)
            and subprocess.run(["pgrep", "-x", proc], capture_output=True).returncode
            == 0
        ):
            subprocess.Popen(
                [binary, "--refresh-platform-policy", "--no-startup-window"],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                start_new_session=True,
            )


def set_shape(shape: str) -> None:
    if not write_if_changed(CURRENT_DIR / "shape", shape + "\n"):
        return
    # templates that draw corners (lazygit)
    generate(current_theme())
    # nvim watches the file
    if subprocess.run(["tmux", "info"], capture_output=True).returncode == 0:
        run_quiet(["tmux", "source-file", str(HOME / ".tmux.conf")])
    restart_yazi()
    btop_corners(shape)


def btop_corners(shape: str) -> None:
    """btop has no includes and rewrites btop.conf itself, so the one line is changed in
    place; a running btop re-reads it on SIGUSR2."""
    conf = HOME / ".config/btop/btop.conf"
    try:
        text = conf.read_text()
    except OSError:
        return
    line = f"rounded_corners = {'false' if shape == 'square' else 'true'}"
    new = re.sub(r"^rounded_corners\s*=.*$", line, text, count=1, flags=re.M)
    if new != text:
        conf.write_text(new)
        run_quiet(["pkill", "-USR2", "-x", "btop"])


def notify_switch(summary: str) -> None:
    """The theme notification. When the boot menu and splash still have other colors
    (hyprdori-theme-boot --check), it says so, and its Update button runs hyprdori-theme-boot in a
    kitty window (password prompt and output)."""
    script = HOME / ".local/bin/hyprdori-theme-boot"
    stale = (
        script.exists()
        and subprocess.run(
            [str(script), "--check"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        ).returncode
        == 0
    )
    if not stale or not shutil.which("notify-send"):
        notify(summary)
        return
    ask = (
        'a=$("$HOME/.local/bin/hyprdori-notify" theme -c x-hyprdori.hint -A update=Update "$1" "$2"); '
        '[ "$a" = update ] && exec "$0" --window'
    )
    body = "Click Update for the bootloader and Plymouth to follow the new theme."
    subprocess.Popen(
        ["bash", "-c", ask, str(script), summary, body],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        start_new_session=True,
    )
