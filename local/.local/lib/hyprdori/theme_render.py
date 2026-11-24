"""Templates into files: the placeholders, where each rendered file goes, and the files made
without a template (the shell's colors, starship, fastfetch, LS_COLORS)."""

import json
import os
import re
import subprocess
import sys
from pathlib import Path

from theme_backgrounds import theme_background
from theme_colors import (
    CURRENT_DIR,
    HEX_RE,
    HOME,
    ICONS_DIR,
    STATE_FILE,
    TEMPLATES_DIR,
    current_shape,
    current_theme,
    load_theme,
    mix,
)

# Rendered files that also need a copy somewhere an app can find them
SPICETIFY_DIR = Path(os.environ.get("XDG_CONFIG_HOME", HOME / ".config")) / "spicetify"
EXTRA_DESTINATIONS = {
    "hyprland.lua": HOME / ".config/hypr/configs/generated/theme.lua",
    # btop and bat find themes by name in their own themes folders
    "btop.theme": HOME / ".config/btop/themes/current.theme",
    "bat.tmTheme": HOME / ".config/bat/themes/Current.tmTheme",
    "cava": HOME / ".config/cava/themes/current",
    "yazi-theme.toml": HOME / ".config/yazi/theme.toml",
    # catppuccin/tmux may be at plugins/catppuccin/tmux and, through TPM, at
    # plugins/tmux. Every copy gets the flavor, since the last one loaded wins.
    "tmux.conf": [
        HOME / ".tmux/plugins/catppuccin/tmux/themes/catppuccin_current_tmux.conf",
        HOME / ".tmux/plugins/tmux/themes/catppuccin_current_tmux.conf",
    ],
    "cliamp.toml": HOME / ".config/cliamp/themes/system.toml",
    # Spotify's colors and look (Spicetify's "hyprdori" theme; hyprdori-spicetify sets it up)
    "spicetify-color.ini": SPICETIFY_DIR / "Themes/hyprdori/color.ini",
    "spicetify-user.css": SPICETIFY_DIR / "Themes/hyprdori/user.css",
    # eza's icons, the same as yazi's (theme/eza-icons.py writes the template)
    "eza-theme.yml": HOME / ".config/eza/theme.yml",
    # GTK adds these to whatever theme is set
    "gtk.css": HOME / ".config/gtk-3.0/gtk.css",
    "gtk4.css": HOME / ".config/gtk-4.0/gtk.css",
    "gtk-settings.ini": [
        HOME / ".config/gtk-3.0/settings.ini",
        HOME / ".config/gtk-4.0/settings.ini",
    ],
    "kdeglobals": HOME / ".config/kdeglobals",
    "qt5ct.conf": HOME / ".config/qt5ct/qt5ct.conf",
    "qt6ct.conf": HOME / ".config/qt6ct/qt6ct.conf",
    "kvantum.kvconfig": HOME / ".config/Kvantum/kvantum.kvconfig",
    "kvantum-current.kvconfig": HOME / ".config/Kvantum/current/current.kvconfig",
    "kvantum-current.svg": HOME / ".config/Kvantum/current/current.svg",
    "hyprtoolkit.conf": HOME / ".config/hypr/hyprtoolkit.conf",
    "cursor-index.theme": HOME / ".icons/default/index.theme",
    "sddm-cursor.conf": Path("/var/lib/hyprdori/cursor.conf"),
    # the login screen; that folder only exists after sddm/install.sh
    "sddm-theme.conf": Path("/var/lib/hyprdori/theme.conf"),
}
# Written only when the app's folder exists (don't create a half plugin dir)
# only where the app's folder is there already (Spicetify's Themes: once it has run)
ONLY_IF_PRESENT = {
    "tmux.conf",
    "cliamp.toml",
    "spicetify-color.ini",
    "spicetify-user.css",
}

FASTFETCH_SOURCE = HOME / ".config/fastfetch/base.jsonc"

FASTFETCH_OUTPUT = HOME / ".config/fastfetch/config.jsonc"
STARSHIP_SOURCE = HOME / ".config/starship/base.toml"
STARSHIP_OUTPUT = HOME / ".config/starship.toml"

# {{ name }}, {{ name.hex }}, {{ mix a b 30% }}: words on one line (Vim's {{{ folds aren't)
PLACEHOLDER_RE = re.compile(r"\{\{[ \t]*([A-Za-z_][\w.]*(?:[ \t]+[^{}\s]+)*)[ \t]*\}\}")


def gradient(spec: str, colors: dict) -> tuple[list[str], str]:
    """A border spec ("rgba(..) rgba(..) 45deg", or a color name) as its colors and angle."""
    parts, angle = [], ""
    for part in spec.split():
        if re.fullmatch(r"-?\d+(\.\d+)?deg", part):
            angle = part[:-3]
        else:
            parts.append(colors.get(part, part))
    return parts, angle


def theme_ref(ref: str, fallback: str, theme: dict) -> str:
    """A theme value by name (a border gradient or a color), else the fallback (a name or
    a literal value)."""
    values = theme["specs"] | theme["colors"]
    return values.get(ref) or values.get(fallback) or fallback or ref


def render(text: str, theme: dict, source: str) -> str:
    colors, strings = theme["colors"], theme["strings"]

    def color_format(value: str, fmt: str, key: str) -> str:
        if fmt == "":
            return value
        if fmt in ("hex", "strip"):
            return value[1:]
        if fmt == "rgb":
            return ", ".join(str(int(value[i : i + 2], 16)) for i in (1, 3, 5))
        if fmt == "ansi":  # 24-bit SGR foreground code, e.g. for fastfetch
            return "38;2;" + ";".join(str(int(value[i : i + 2], 16)) for i in (1, 3, 5))
        if fmt == "ansi_bg":  # the same as a background
            return "48;2;" + ";".join(str(int(value[i : i + 2], 16)) for i in (1, 3, 5))
        raise KeyError(f"{source}: unknown placeholder {{{{ {key} }}}}")

    def substitute(match: re.Match) -> str:
        expr = match.group(1).strip()
        words = expr.split()
        # {{ mix a b 30% }}, mix_strip (no #), mix_rgb ("r,g,b"), and mix.rgb, mix.hex, mix.ansi
        # like the colors' own formats
        if words[0].startswith("mix.") and len(words) == 4:
            mixed = substitute(re.match(r"(.*)", "mix " + " ".join(words[1:])))
            return color_format(mixed, words[0][4:], expr)
        if words[0] in ("mix", "mix_strip", "mix_rgb") and len(words) == 4:
            start, end = (
                colors.get(w, w if HEX_RE.match(w) else None) for w in words[1:3]
            )
            if not start or not end:
                raise KeyError(f"{source}: unknown color in {{{{ {expr} }}}}")
            amount = float(words[3].rstrip("%"))
            mixed = mix(
                start,
                end,
                amount / 100 if words[3].endswith("%") or amount > 1 else amount,
            )
            if words[0] == "mix_strip":
                return mixed[1:]
            if words[0] == "mix_rgb":
                return ",".join(str(int(mixed[i : i + 2], 16)) for i in (1, 3, 5))
            return mixed
        # {{ hypr_gradient key fallback }}: a Hyprland Lua color or gradient
        if words[0] in ("hypr_gradient", "shell_gradient", "gradient_start") and len(
            words
        ) in (2, 3):
            parts, angle = gradient(
                theme_ref(words[1], words[2] if len(words) == 3 else "", theme), colors
            )
            if words[0] == "gradient_start":
                first = parts[0] if parts else ""
                found = re.fullmatch(r"(?i)rgba?\(([0-9a-f]{6})[0-9a-f]{0,2}\)", first)
                return "#" + found.group(1).lower() if found else first
            if words[0] == "shell_gradient":
                return " ".join(parts) + (f" {angle}deg" if angle else "")
            if len(parts) == 1:
                return json.dumps(parts[0])
            body = "{ colors = { " + ", ".join(json.dumps(c) for c in parts) + " }"
            return body + (f", angle = {angle} }}" if angle else " }")
        if len(words) == 1:
            name, _, fmt = expr.partition(".")
            if fmt == "" and name.endswith("_strip") and name[:-6] in colors:
                return colors[name[:-6]][1:]
            if name in colors:
                return color_format(colors[name], fmt, expr)
            if name in strings and fmt == "":
                return strings[name]
            if name in theme["specs"] and fmt == "":
                return theme["specs"][name]
        raise KeyError(f"{source}: unknown placeholder {{{{ {expr} }}}}")

    return PLACEHOLDER_RE.sub(substitute, text)


def write_if_changed(path: Path, content: str) -> bool:
    path.parent.mkdir(parents=True, exist_ok=True)
    try:
        if path.read_text() == content:
            return False
    except FileNotFoundError:
        pass
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_text(content)
    tmp.replace(path)  # atomic, so file watchers never see a half-written file
    return True


def render_fastfetch(theme: dict) -> None:
    """fastfetch has no includes either: config.jsonc is base.jsonc with the
    theme's colors filled in (read on every run)."""
    if not FASTFETCH_SOURCE.exists():
        return
    header = "// Generated by hyprdori-theme-set from ~/.config/fastfetch/base.jsonc; edit that file\n"
    try:
        content = render(FASTFETCH_SOURCE.read_text(), theme, "fastfetch/base.jsonc")
    except KeyError as e:  # a typo in base.jsonc must not stop the theme switch
        print(f"theme-set: {e}", file=sys.stderr)
        return
    write_if_changed(FASTFETCH_OUTPUT, header + content)


def render_starship(theme: dict) -> None:
    """starship has no includes: ~/.config/starship.toml is generated from
    ~/.config/starship/base.toml plus the palette (starship rereads it every prompt)."""
    if not STARSHIP_SOURCE.exists():
        return
    base = re.sub(
        r"^palette\s*=.*$",
        "palette = 'theme'",
        STARSHIP_SOURCE.read_text(),
        count=1,
        flags=re.M,
    )
    # base.toml's own palette is the fallback; the theme's replaces it
    base = re.sub(r"\n# [^\n]*\n\[palettes\.theme\][\s\S]*$", "\n", base)
    # square corners in Work or Game or with the corner radius at 0 (--shape)
    if current_shape() == "square":
        base = base.replace("╭", "┌").replace("╰", "└")
    palette = "\n[palettes.theme]\n" + "".join(
        f'{name} = "{value}"\n'
        for name, value in theme["colors"].items()
        if not name.startswith("color")
    )
    header = "# Generated by hyprdori-theme-set from ~/.config/starship/base.toml; edit that file\n"
    write_if_changed(STARSHIP_OUTPUT, header + base.rstrip() + "\n" + palette)


def icons_dir(name: str) -> str:
    """Power menu icons from hyprdori-theme-icons, or Catppuccin's for a theme
    that has none yet."""
    for candidate in (name, "catppuccin"):
        if (ICONS_DIR / candidate / "lock.svg").is_file():
            return str(ICONS_DIR / candidate)
    return ""


def render_quickshell(theme: dict) -> None:
    background = theme_background(theme)
    theme["background"] = background
    data = {
        "theme": theme["strings"]["theme"],
        "name": theme["strings"]["theme_name"],
        "mode": theme["strings"]["mode"],
        "icons": icons_dir(theme["strings"]["theme"]),
        "colors": theme["colors"],
        # the lock screen shows it unless another image is chosen (Settings > Style > Lock screen)
        "background": str(background) if background else "",
    }
    write_if_changed(CURRENT_DIR / "quickshell.json", json.dumps(data, indent=2) + "\n")


def render_ls_colors() -> None:
    """dircolors' output for .zshrc, so shells set LS_COLORS without running it."""
    # dircolors outputs nothing unless TERM matches, and the shell's picker and autostart have none
    env = os.environ | {"TERM": "xterm-256color"}
    out = subprocess.run(
        ["dircolors", "-b", str(CURRENT_DIR / "dir_colors")],
        capture_output=True,
        text=True,
        env=env,
    )
    if out.returncode == 0:
        write_if_changed(CURRENT_DIR / "ls_colors.zsh", out.stdout)
    else:
        print(f"theme-set: dircolors: {out.stderr.strip()}", file=sys.stderr)


def generate(name: str) -> dict:
    theme = load_theme(name)
    theme["changed"] = set()
    for tpl in sorted(TEMPLATES_DIR.glob("*.tpl")):
        out_name = tpl.name.removesuffix(".tpl")
        content = render(tpl.read_text(), theme, tpl.name)
        write_if_changed(CURRENT_DIR / out_name, content)
        targets = EXTRA_DESTINATIONS.get(out_name, [])
        for dest in targets if isinstance(targets, list) else [targets]:
            if out_name in ONLY_IF_PRESENT and not dest.parent.parent.is_dir():
                continue
            if out_name.startswith("sddm-") and not dest.parent.is_dir():
                continue
            if (
                out_name == "tmux.conf"
                and not (dest.parent.parent / "catppuccin.tmux").is_file()
            ):
                continue  # some other plugin named "tmux"
            try:
                if write_if_changed(dest, content):
                    theme["changed"].add(out_name)
            except OSError as e:
                print(f"theme-set: could not write {dest}: {e}", file=sys.stderr)

    render_quickshell(theme)
    render_starship(theme)
    render_fastfetch(theme)

    # A theme may ship its own file for any app (e.g. a hand-tuned btop.theme);
    # it replaces the rendered one.
    for override in theme["dir"].iterdir():
        if override.name != "colors.toml" and override.is_file():
            write_if_changed(CURRENT_DIR / override.name, override.read_text())

    render_ls_colors()
    write_if_changed(STATE_FILE, name + "\n")
    return theme


def write_hypr_look() -> None:
    """Only Hyprland's generated theme.lua again, with the gaps, border width, corners,
    opacity, blur and animations from Settings, so Hyprland starts with them (the shell applies them live)."""
    theme = load_theme(current_theme())
    content = render(
        (TEMPLATES_DIR / "hyprland.lua.tpl").read_text(), theme, "hyprland.lua.tpl"
    )
    write_if_changed(CURRENT_DIR / "hyprland.lua", content)
    write_if_changed(EXTRA_DESTINATIONS["hyprland.lua"], content)
