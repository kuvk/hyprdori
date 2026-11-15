"""Each theme's own background: which image it is, the standard one drawn from the logos, and
the desktop following it."""

import hashlib
import json
import os
from pathlib import Path

from theme_colors import HOME, run_quiet, shell_settings

LOGOS = (HOME / ".config/theme/logo/dori-logo", HOME / ".config/theme/logo/dori-text")


def logo_checksum(*commands: Path) -> str:
    """The logo files and the commands that draw them, so a changed logo is drawn again."""
    drawn = hashlib.sha256()
    for part in (*LOGOS, HOME / ".local/bin/hyprdori-logo-render", *commands):
        try:
            drawn.update(part.read_bytes())
        except OSError:
            pass
    return drawn.hexdigest()[:8]


BACKGROUNDS_DIR = (
    Path(os.environ.get("XDG_DATA_HOME", HOME / ".local/share"))
    / "hyprdori/backgrounds/default"
)
# Which image is each theme's background, by theme: a file name in its folder (--theme-default)
THEME_DEFAULTS = (
    Path(os.environ.get("XDG_STATE_HOME", HOME / ".local/state"))
    / "hyprdori/theme-backgrounds.json"
)
IMAGE_SUFFIXES = {".png", ".jpg", ".jpeg", ".webp"}


def theme_defaults() -> dict:
    try:
        data = json.loads(THEME_DEFAULTS.read_text())
        return data if isinstance(data, dict) else {}
    except (OSError, json.JSONDecodeError):
        return {}


def set_theme_default(name: str, path: Path) -> None:
    data = theme_defaults()
    data[name] = path.name
    THEME_DEFAULTS.parent.mkdir(parents=True, exist_ok=True)
    tmp = THEME_DEFAULTS.with_suffix(".tmp")
    tmp.write_text(json.dumps(data, indent=2) + "\n")
    tmp.replace(THEME_DEFAULTS)


def theme_folder(name: str) -> Path:
    """A theme's own wallpapers (backgrounds/default/<theme>/): the picker shows the current
    theme's folder only."""
    return BACKGROUNDS_DIR / name


def is_theme_wallpaper(path: Path, name: str) -> bool:
    return (
        path.parent == theme_folder(name)
        and path.name.startswith("dori")
        and path.suffix.lower() in IMAGE_SUFFIXES
    )


def theme_background(theme: dict) -> Path | None:
    """This theme's own background, which the wallpaper and the lock screen show while they
    follow the theme (Settings): the image chosen for it (a dori* image in its folder, set by the
    wallpaper generator or by picking one, --theme-default); with that gone, the newest dori*
    image there; with none, the standard one, the logos in magenta on the dark background
    (hyprdori-logo-wallpaper), drawn again when the colors or the logos change."""
    colors, name = theme["colors"], theme["strings"]["theme"]
    folder = theme_folder(name)
    drawn = logo_checksum(HOME / ".local/bin/hyprdori-logo-wallpaper")
    standard = (
        folder
        / f"dori-theme-{colors['magenta'][1:]}-on-{colors['dark_background'][1:]}-{drawn}.png"
    )
    chosen = (
        folder / theme_defaults().get(name, "") if theme_defaults().get(name) else None
    )
    if (
        chosen
        and chosen.is_file()
        and is_theme_wallpaper(chosen, name)
        and not chosen.name.startswith("dori-theme-")
    ):
        return chosen
    if not (chosen and chosen.name.startswith("dori-theme-")):
        # the chosen one is gone (or none was): the newest made for this theme
        made = (
            sorted(
                (
                    p
                    for p in folder.glob("dori*")
                    if is_theme_wallpaper(p, name)
                    and not p.name.startswith("dori-theme-")
                ),
                key=lambda p: p.stat().st_mtime,
                reverse=True,
            )
            if folder.is_dir()
            else []
        )
        if made:
            set_theme_default(name, made[0])
            return made[0]
    if not standard.exists():
        folder.mkdir(parents=True, exist_ok=True)
        for old in folder.glob(
            "dori-theme-*.png"
        ):  # this theme in older colors or logos
            old.unlink(missing_ok=True)
        run_quiet(
            [
                str(HOME / ".local/bin/hyprdori-logo-wallpaper"),
                "--bg",
                colors["dark_background"],
                "--fg",
                colors["magenta"],
                "--output",
                str(standard),
            ]
        )
    if standard.exists():
        set_theme_default(name, standard)
        return standard
    return None


def follow_wallpaper(theme: dict) -> None:
    """The theme's background (theme_background) on every monitor while the wallpaper
    follows the theme: picking the theme's own background turns that on (the wallpaper
    picker, Settings > Style > Background > Theme's), picking another turns it off. The lock screen follows the
    theme on its own (Settings > Style > Lock screen)."""
    if not shell_settings().get("wallpaperFollowsTheme"):
        return
    path = theme.get("background") or theme_background(theme)
    if not path:
        return
    current = HOME / ".local/state/wallpaper/current"
    if current.resolve() != path.resolve():
        run_quiet(
            [str(HOME / ".local/bin/hyprdori-wallpaper"), "set", "static", str(path)]
        )
