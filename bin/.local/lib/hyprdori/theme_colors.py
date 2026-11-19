"""A theme as data: where the themes are, the shell's settings, and a theme's colors and strings
as the templates use them (load_theme). For hyprdori-theme-set and what reads themes as it does
(hyprdori-theme-icons, hyprdori-check)."""

import json
import os
import re
import shutil
import subprocess
import sys
import tomllib
from pathlib import Path

HOME = Path.home()
THEME_DIR = HOME / ".config/theme"
THEMES_DIR = THEME_DIR / "themes"
# Hyprdori's changes to a theme's colors (overrides/<name>.toml), kept apart so syncing the
# themes doesn't touch them
OVERRIDES_DIR = THEME_DIR / "overrides"
TEMPLATES_DIR = THEME_DIR / "templates"
CURRENT_DIR = THEME_DIR / "current"
ICONS_DIR = THEME_DIR / "icons"
STATE_FILE = CURRENT_DIR / "theme"
DEFAULT_THEME = "catppuccin"

# there or not: browsers keep the display font with Monospace everywhere (hyprdori-browser-theme-setup)
BROWSER_DISPLAY_FONT = (
    Path(os.environ.get("XDG_CONFIG_HOME", HOME / ".config"))
    / "hyprdori/browser-display-font"
)

# The named colors in every theme's colors.toml (missing ones are worked out)
PALETTE = (
    "background dark_background darker_background lighter_background "
    "foreground dark_foreground light_foreground bright_foreground "
    "accent selection muted "
    "red yellow orange green cyan blue magenta brown "
    "bright_red bright_yellow bright_green bright_cyan bright_blue bright_magenta"
).split()
# Older names that themes and templates may still use
LEGACY_PALETTE = {
    "bg": "background",
    "dark_bg": "dark_background",
    "darker_bg": "darker_background",
    "lighter_bg": "lighter_background",
    "fg": "foreground",
    "dark_fg": "dark_foreground",
    "light_fg": "light_foreground",
    "bright_fg": "bright_foreground",
}
ANSI = (
    "background red green yellow blue magenta cyan foreground "
    "muted bright_red bright_green bright_yellow bright_blue bright_magenta bright_cyan bright_foreground"
).split()
CURSOR_DIRS = (HOME / ".icons", HOME / ".local/share/icons", Path("/usr/share/icons"))

HINTINGS = ("none", "slight", "medium", "full")
ANTIALIASINGS = ("none", "grayscale", "rgba")

# --cursor sets these: Quickshell may not have saved the choice to its file yet
SETTINGS_OVERRIDE: dict = {}

HEX_RE = re.compile(r"^#[0-9a-fA-F]{6}$")


def notify(body: str) -> None:
    subprocess.run([str(HOME / ".local/bin/hyprdori-notify"), "theme", body], check=False)


def run_quiet(cmd: list[str]) -> None:
    if shutil.which(cmd[0]):
        subprocess.run(
            cmd, check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL
        )


def available_themes() -> list[str]:
    if not THEMES_DIR.is_dir():
        return []
    return sorted(p.parent.name for p in THEMES_DIR.glob("*/colors.toml"))


def current_theme() -> str:
    try:
        name = STATE_FILE.read_text().strip()
    except FileNotFoundError:
        return DEFAULT_THEME
    return name or DEFAULT_THEME


def current_shape() -> str:
    try:
        return (CURRENT_DIR / "shape").read_text().strip()
    except FileNotFoundError:
        return "rounded"


ICONS_FILE = THEME_DIR / "icons.toml"


def icon_strings(colors: dict) -> dict:
    """icons.toml as yazi [icon] lines and a Lua table for Neovim, in this theme's colors:
    folders accent, links cyan, files and extensions in their own color (a theme color
    name or #hex)."""
    try:
        icons = tomllib.loads(ICONS_FILE.read_text())
    except (OSError, tomllib.TOMLDecodeError) as e:
        print(f"theme-set: {ICONS_FILE}: {e}", file=sys.stderr)
        icons = {}
    color = lambda c: colors.get(
        c, c if HEX_RE.match(c or "") else colors["foreground"]
    )
    toml = lambda v: json.dumps(v, ensure_ascii=False)
    dirs = [(n, d["icon"]) for d in icons.get("dir", []) for n in d.get("names", [])]
    files = [
        (n, f["icon"], color(f.get("color", "text")))
        for f in icons.get("file", [])
        for n in f.get("names", [])
    ]
    exts = [
        (n, e["icon"], color(e.get("color", "text")))
        for e in icons.get("ext", [])
        for n in e.get("names", [])
    ]
    link = icons.get("link", {})
    lua = lambda v: json.dumps(
        v, ensure_ascii=False
    )  # a JSON string is a Lua string literal
    lua_entries = (
        lambda rows: "{ "
        + ", ".join(f"[{lua(n)}] = {{ {lua(i)}, {lua(c)} }}" for n, i, c in rows)
        + " }"
    )
    return {
        "yazi_icon_dirs": "\n".join(
            f'\t{{ name = {toml(n)}, text = {toml(i)}, fg = {toml(colors["accent"])} }},'
            for n, i in dirs
        ),
        "yazi_icon_files": "\n".join(
            f"\t{{ name = {toml(n)}, text = {toml(i)}, fg = {toml(c)} }},"
            for n, i, c in files
        ),
        "yazi_icon_exts": "\n".join(
            f"\t{{ name = {toml(n)}, text = {toml(i)}, fg = {toml(c)} }},"
            for n, i, c in exts
        ),
        "icon_link_dir": toml(link.get("dir", "\ue5ff"))[1:-1],
        "icon_link_file": toml(link.get("file", "\uf15b"))[1:-1],
        "icon_link_broken": toml(link.get("broken", "\U000f086f"))[1:-1],
        "nvim_icons": "{ dirs = { "
        + ", ".join(f"[{lua(n)}] = {lua(i)}" for n, i in dirs)
        + " }, files = "
        + lua_entries(files)
        + ", exts = "
        + lua_entries(exts)
        + f", link_dir = {lua(link.get('dir', chr(0xe5ff)))}, link_file = {lua(link.get('file', chr(0xf15b)))}"
        + f", link_broken = {lua(link.get('broken', chr(0xf086f)))} }}",
    }


# The settings read from Quickshell's Settings, with the values used until defaults.json or a
# saved settings file has them: the same as the shell's (hyprdori-check compares them)
SETTING_DEFAULTS = {
    "font": "JetBrainsMono Nerd Font",
    "displayFont": "SF Pro Display",
    "monoEverywhere": False,
    "fontHinting": "slight",
    "fontAntialiasing": "rgba",
    "windowButtons": False,
    "wallpaperFollowsTheme": True,
    "lockAvatar": False,
    "lockPowerOpacity": 85,
    "accentOverrides": {},
    "lockInputOpacity": 75,
    "cursorTheme": "Adwaita",
    "cursorSize": 24,
    # Hyprland's look in Default (hyprland.lua.tpl)
    "radius": 10,
    "gapsIn": 5,
    "gapsOut": 10,
    "activeOpacity": 0.95,
    "inactiveOpacity": 0.88,
    "blur": True,
    "iconTheme": "Papirus",
}


def shell_settings() -> dict:
    """What's chosen in Quickshell's Settings: the saved settings (the newest file, should
    there be more than one), then the shell's defaults.json (a fresh install, before the shell
    has saved any), then SETTING_DEFAULTS."""
    settings = dict(SETTING_DEFAULTS)
    sources = [HOME / ".config/quickshell/config/defaults.json"]
    sources += sorted(
        (HOME / ".local/state/quickshell/by-shell").glob("*/settings.json"),
        key=lambda path: path.stat().st_mtime,
    )
    for path in sources:
        try:
            saved = json.loads(path.read_text())
        except (OSError, json.JSONDecodeError):
            continue
        settings.update({key: saved[key] for key in settings if key in saved})
        # settings saved before these names: the Nerd Font was the terminals' font, and
        # "Nerd Fonts only" put it everywhere
        if "font" not in saved and saved.get("nerdFont"):
            settings["font"] = saved["nerdFont"]
        if "monoEverywhere" not in saved and "nerdFontOnly" in saved:
            settings["monoEverywhere"] = bool(saved["nerdFontOnly"])
    return settings | SETTINGS_OVERRIDE


def cursor_themes() -> list[str]:
    names = {
        path.parent.parent.name
        for folder in CURSOR_DIRS
        for path in folder.glob("*/cursors/left_ptr")
        if path.parent.parent.name != "default"
    }
    return sorted(names, key=str.lower)


def icon_themes() -> list[str]:
    names = set()
    for folder in CURSOR_DIRS:
        for index in folder.glob("*/index.theme"):
            if index.parent.name in ("default", "hicolor"):
                continue
            text = index.read_text(errors="ignore")
            # cursor themes have an index.theme too, without icon folders
            if re.search(r"^Directories\s*=\s*\S", text, re.M) and not re.search(
                r"^Hidden\s*=\s*true", text, re.M | re.I
            ):
                names.add(index.parent.name)
    return sorted(names, key=str.lower)


def icon_theme_for(name: str, mode: str) -> str:
    """A theme with a variant for the mode uses it, so Papirus follows light and dark;
    choosing the variant itself (Papirus-Dark) keeps it in both."""
    variant = f"{name}-{mode.capitalize()}"
    return variant if variant in icon_themes() else name


def mix(a: str, b: str, amount: float) -> str:
    """a blended toward b by amount (0..1), as #rrggbb."""
    ca = [int(a[i : i + 2], 16) for i in (1, 3, 5)]
    cb = [int(b[i : i + 2], 16) for i in (1, 3, 5)]
    return "#" + "".join(
        f"{int(x * (1 - amount) + y * amount + 0.5):02x}" for x, y in zip(ca, cb)
    )


def palette(data: dict) -> tuple[dict, dict]:
    """A theme's colors with what it leaves out worked out: hex colors,
    and the other values (border gradients like "rgba(..) rgba(..) 45deg") apart."""
    raw = {k: str(v) for k, v in data.items() if isinstance(v, str)}
    c = {k: v.lower() for k, v in raw.items() if HEX_RE.match(v)}
    specs = {
        k: v
        for k, v in raw.items()
        if not HEX_RE.match(v) and k not in ("mode", "theme_type")
    }
    for short, long in LEGACY_PALETTE.items():
        c.setdefault(long, c.get(short, ""))
    for i, name in enumerate(("red", "green", "yellow", "blue", "magenta", "cyan")):
        c.setdefault(name, c.get(f"color{i + 1}", ""))
    for i, name in enumerate(
        (
            "bright_red",
            "bright_green",
            "bright_yellow",
            "bright_blue",
            "bright_magenta",
            "bright_cyan",
        )
    ):
        c.setdefault(name, c.get(f"color{i + 9}", ""))
    c = {k: v for k, v in c.items() if v}
    c.setdefault("background", c.get("color0", "#1e1e2e"))
    c.setdefault("foreground", c.get("color7", "#cdd6f4"))
    c.setdefault("light_foreground", c.get("color7", c["foreground"]))
    c.setdefault("bright_foreground", c.get("color15", c["foreground"]))
    c.setdefault("lighter_background", c.get("color0", c["background"]))
    c.setdefault("dark_foreground", c.get("color8", c["foreground"]))
    c.setdefault("muted", c.get("color8", c["dark_foreground"]))
    c.setdefault(
        "selection", c.get("selection_background", c.get("color8", c["background"]))
    )
    c.setdefault("selection_background", c["selection"])
    c.setdefault("selection_foreground", c["bright_foreground"])
    for hue in ("red", "green", "yellow", "blue", "magenta", "cyan"):
        c.setdefault(hue, c["foreground"])
    c.setdefault("orange", c["yellow"])
    c.setdefault("brown", mix(c["orange"], "#000000", 0.5))
    c.setdefault("dark_background", mix(c["background"], "#000000", 0.25))
    c.setdefault("darker_background", mix(c["background"], "#000000", 0.5))
    for hue in ("red", "yellow", "green", "cyan", "blue", "magenta"):
        c.setdefault(f"bright_{hue}", mix(c[hue], "#ffffff", 0.2))
    c.setdefault("accent", c["blue"])
    c["cursor"] = c["bright_foreground"]
    for i, name in enumerate(ANSI):
        c[f"color{i}"] = c[name]
    return c, specs


def shell_slots(c: dict) -> dict:
    """Colors by the names older settings saved (base, mauve, ...), for an accent chosen
    then; dim text steps evenly from dark_foreground to foreground."""
    fg, dim = c["foreground"], c["dark_foreground"]
    return {
        "base": c["background"],
        "mantle": c["dark_background"],
        "crust": c["darker_background"],
        "surface0": c["lighter_background"],
        "surface1": c["selection"],
        "surface2": c["muted"],
        "overlay0": dim,
        "overlay1": mix(dim, fg, 0.2),
        "overlay2": mix(dim, fg, 0.4),
        "subtext0": mix(dim, fg, 0.6),
        "subtext1": mix(dim, fg, 0.8),
        "text": fg,
        "red": c["red"],
        "maroon": c["bright_red"],
        "peach": c["orange"],
        "yellow": c["yellow"],
        "green": c["green"],
        "teal": c["cyan"],
        "sky": c["bright_cyan"],
        "sapphire": mix(c["blue"], c["cyan"], 0.5),
        "blue": c["blue"],
        "lavender": c["bright_blue"],
        "mauve": c["magenta"],
        "pink": c["bright_magenta"],
        "flamingo": mix(c["red"], fg, 0.5),
        "rosewater": mix(c["bright_red"], c["bright_foreground"], 0.6),
        "accent": c["accent"],
        "accent2": c["accent"],
        "accent3": c["orange"],
        "selection_bg": c["selection_background"],
        "selection_fg": c["selection_foreground"],
    }


def theme_mode(data: dict, colors: dict) -> str:
    mode = data.get("mode") or data.get("theme_type")
    if mode in ("dark", "light"):
        return mode
    bg = colors["background"]
    return "light" if sum(int(bg[i : i + 2], 16) for i in (1, 3, 5)) > 382 else "dark"


def accent_override(name: str, colors: dict) -> str | None:
    """Settings > Style > Accent: one of this theme's colors (or a #hex) instead of
    its own accent; none is the theme's."""
    chosen = shell_settings().get("accentOverrides", {})
    value = chosen.get(name) if isinstance(chosen, dict) else None
    if isinstance(value, dict):  # saved by the shell's older Settings: {accent: name}
        value = value.get("accent")
    if isinstance(value, str):
        if HEX_RE.match(value):
            return value.lower()
        return colors.get(value) or shell_slots(colors).get(value)
    return None


def nvim_colorscheme(folder: Path, mode: str) -> str:
    """The colorscheme the theme's neovim.lua names (a LazyVim spec); aether, drawn from the
    palette, for a theme without one."""
    try:
        match = re.search(
            r'colorscheme\s*=\s*"([^"]+)"', (folder / "neovim.lua").read_text()
        )
    except OSError:
        match = None
    return match.group(1) if match else "aether"


def gtk_font_pt() -> str:
    """GTK's and Qt's font size in points for Displays > Text size (px, kept by
    hyprdori-monitors): the shell's text size, as kitty's (0.75 pt a px, so 12 px is 9 pt, 14 px
    10.5). Set as the font size rather than GTK's text-scaling-factor, which Electron apps on
    Wayland (Obsidian, Mullvad) apply to their content without resizing the window, leaving
    an empty strip."""
    try:
        size = int(
            json.loads((HOME / ".config/hypr/monitors.json").read_text()).get(
                "text_size", 12
            )
        )
    except (OSError, ValueError, TypeError, AttributeError):
        size = 12
    return f"{max(6.0, round(size * 0.75 * 2) / 2):g}"


def load_theme(name: str) -> dict:
    path = THEMES_DIR / name / "colors.toml"
    with path.open("rb") as f:
        data = tomllib.load(f)
    override = OVERRIDES_DIR / f"{name}.toml"
    if override.is_file():
        with override.open("rb") as f:
            data |= tomllib.load(f)
    colors, specs = palette(data)
    colors["accent"] = accent_override(name, colors) or colors["accent"]
    mode = theme_mode(data, colors)

    shell = shell_settings()
    hinting, antialiasing = shell["fontHinting"], shell["fontAntialiasing"]
    strings = {
        "theme": name,
        "theme_name": data.get("name") or name.replace("-", " ").title(),
        "mode": mode,
        "theme_type": mode,
        "nvim_colorscheme": nvim_colorscheme(path.parent, mode),
        "cursor_theme": shell["cursorTheme"],
        "cursor_size": str(shell["cursorSize"]),
        # Settings > Fonts: the terminals' font (also monospace), and what apps show text in
        "nerd_font": shell["font"],
        "text_font": shell["font"] if shell["monoEverywhere"] else shell["displayFont"],
        # the browsers' own text (tabs, address bar, menus; fontconfig.conf): the display font
        # with Monospace everywhere when they don't follow the font (hyprdori-browser-theme-setup
        # --follow-font false), else the same as everything else (the rule changes nothing)
        "browser_font": (
            shell["displayFont"]
            if shell["monoEverywhere"] and BROWSER_DISPLAY_FONT.exists()
            else (shell["font"] if shell["monoEverywhere"] else shell["displayFont"])
        ),
        "font_hinting": hinting,
        "font_antialiasing": antialiasing,
        "gtk_font_pt": gtk_font_pt(),
        # the cursor line in Neovim's neo-tree (Catppuccin's: surface0 64% over base); yazi's
        # hover highlight uses it too
        "cursorline": mix(colors["background"], colors["lighter_background"], 0.64),
        # yazi's hover highlight ends: rounded caps, or full blocks. yazi draws these in the
        # highlight's color (a space would come out in the background's), so either way the
        # bar starts one character before the icon.
        "yazi_pad_open": "\u2588" if current_shape() == "square" else "\ue0b6",
        "yazi_pad_close": "\u2588" if current_shape() == "square" else "\ue0b4",
        "fc_antialias": "false" if antialiasing == "none" else "true",
        "fc_hinting": "false" if hinting == "none" else "true",
        "fc_hintstyle": f"hint{hinting}",
        "fc_rgba": "rgb" if antialiasing == "rgba" else "none",
        "fc_lcdfilter": "lcddefault" if antialiasing == "rgba" else "lcdnone",
        "xft_antialias": "0" if antialiasing == "none" else "1",
        "xft_hinting": "0" if hinting == "none" else "1",
        "decoration_layout": ":close" if shell["windowButtons"] else ":",
        "border_style": "single" if current_shape() == "square" else "rounded",
        "hypr_gaps_in": str(int(shell["gapsIn"])),
        "hypr_gaps_out": str(int(shell["gapsOut"])),
        "hypr_rounding": str(int(shell["radius"])),
        "hypr_active_opacity": f"{float(shell['activeOpacity']):g}",
        "hypr_inactive_opacity": f"{float(shell['inactiveOpacity']):g}",
        "hypr_blur": "true" if shell["blur"] else "false",
        # the login screen, as the lock screen: the theme's colors
        "login_avatar": colors["accent"],
        "login_inputOutline": colors["accent"],
        # the password field's and buttons' fill: the background with 5% of the text color, as
        # Omarchy's field (lock, login and boot screens)
        "login_input": mix(colors["background"], colors["foreground"], 0.05),
        "login_dots": colors["foreground"],
        "login_text": colors["foreground"],
        "login_check": mix(colors["foreground"], colors["background"], 0.5),
        "login_fail": colors["red"],
        "login_caps": colors["yellow"],
        "login_show_avatar": "true" if shell["lockAvatar"] else "false",
        "login_power_bg": mix(colors["background"], colors["foreground"], 0.05),
        "login_power_opacity": str(shell["lockPowerOpacity"] / 100),
        # outlined like the password field, in the accent; lighter under the cursor
        "login_power_outline": colors["accent"],
        "login_power_hover_outline": mix(colors["accent"], colors["foreground"], 0.4),
        "login_input_opacity": str(shell["lockInputOpacity"] / 100),
        # the password field's corners (lock, login and boot screens) and the login screen's
        # buttons: the windows' corner radius (Settings > Style), square at 0
        "login_radius": str(int(shell["radius"])),
        "icon_theme": icon_theme_for(shell["iconTheme"], mode),
        "prefer_dark": "0" if mode == "light" else "1",
        # adw-gtk3, when installed, follows gtk.css in plain GTK3 and GTK4 apps too;
        # Adwaita only does in libadwaita apps
        "gtk_theme": (
            "adw-gtk3" if Path("/usr/share/themes/adw-gtk3").is_dir() else "Adwaita"
        )
        + ("" if mode == "light" else "-dark"),
    }
    strings.update(icon_strings(colors))  # icons.toml: folder, file and link icons

    return {"colors": colors, "specs": specs, "strings": strings, "dir": path.parent}


def themes_json() -> str:
    current = current_theme()
    result = []
    for name in available_themes():
        try:
            theme = load_theme(name)
        except (ValueError, tomllib.TOMLDecodeError) as e:
            print(e, file=sys.stderr)
            continue
        c = theme["colors"]
        result.append(
            {
                "theme": name,
                "name": theme["strings"]["theme_name"],
                "mode": theme["strings"]["mode"],
                "current": name == current,
                # for the theme carousel's palette preview cards
                "colors": {
                    k: c[k]
                    for k in (
                        "background",
                        "dark_background",
                        "darker_background",
                        "lighter_background",
                        "selection",
                        "dark_foreground",
                        "foreground",
                        "accent",
                        "red",
                        "orange",
                        "yellow",
                        "green",
                        "cyan",
                        "blue",
                        "magenta",
                        "bright_magenta",
                    )
                },
            }
        )
    return json.dumps(result)
