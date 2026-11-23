#!/usr/bin/env bash
# Installs Limine on the ESP and writes its menu: one entry per kernel in /efi/arch
# (mkinitcpio's presets put kernels and images there), styled like the boot splash:
# the logo in magenta above an "Arch Linux" tree of kernels in accent, the text logo below.
# Run it again after a Limine update, a new kernel, or to change colors.
#
#   sudo limine/install.sh             the current theme's colors, accents included
#                                      (hyprdori-theme-set; Catppuccin Mocha before it has run)
#   sudo limine/install.sh --theme     the same, but stop if there's no theme yet
#   sudo limine/install.sh --plain     a plain menu: the same entries in Limine's own look, no
#                                      wallpaper, and no longer Hyprdori's (uninstall.sh), so
#                                      hyprdori-update and the theme leave it alone
#   limine/install.sh --print          print the config instead, without installing
#   limine/install.sh --preview FILE   draw the wallpaper (the logos, no menu text) to FILE
#   sudo limine/install.sh --scan      print entries for the other systems on this machine's
#                                      internal drives, ready for the entries file below;
#                                      nothing is written
#   --resolution WxH                   the menu's resolution; by default the native mode of the
#                                      boot display's screen (the logo is placed for it)
#
# Kernel options come from /etc/kernel/cmdline (made from the running system's on first run).
# At boot, E on an entry edits its options for that boot only.
#
# The menu is /efi/limine.conf (Limine's last place to look, so nothing may sit in EFI/limine or
# EFI/BOOT, where Limine's fallback copy is: the one firmware starts without boot entries).
# It's written whole, so entries added there are lost: other systems' entries (Windows, another
# distro, the UEFI shell) go in /etc/hyprdori/limine-entries.conf, added as written below the
# Arch Linux ones. Above its first entry the same file may set four menu options, in place of
# Hyprdori's: timeout (3), quiet (no: the menu shown), remember_last_entry (no) and
# default_entry (Arch Linux/ and the first kernel). install.sh makes that file, with only
# comments, from limine/limine-entries.conf; with nothing set in it the menu is the same as
# without it.
# With snapshots (a btrfs root and limine-snapper-sync, set up by install.sh) the Arch Linux
# entry gets a Snapshots folder, which limine-snapper-sync fills: it's filled again after
# every rewrite here.
set -euo pipefail

here=$(dirname "$(readlink -f "$0")")
esp=/efi
kernels=/efi/arch
mode=install
use_theme=false
plain=false
resolution=
options="$*"  # kept in limine.conf, so hyprdori-update can run this again the same way
while (($#)); do
    case $1 in
        --theme) use_theme=true ;;
        --plain) plain=true ;;
        --print) mode=print ;;
        --preview) mode=preview; preview=${2:?--preview needs a file}; shift ;;
        --resolution) resolution=${2:?--resolution needs WxH}; shift ;;
        --scan) mode=scan ;;
        *) echo "usage: $0 [--theme | --plain] [--resolution WxH] [--print | --preview FILE | --scan]" >&2; exit 1 ;;
    esac
    shift
done

extra=/etc/hyprdori/limine-entries.conf

# --scan: the boot loaders on every EFI system partition of the internal drives (USB drives
# left out: an entry for one breaks once it's unplugged), as entries for $extra. The others are
# mounted read-only for a moment; this machine's own Limine, its fallback copy and EFI/tools are
# skipped, and so is a loader the file already names. Names come from the firmware's boot
# entries where one points at the same file.
scan() {
    ((EUID == 0)) || { echo "Run it with sudo: sudo $0 --scan (it mounts the other ESPs read-only)" >&2; exit 1; }
    local own esp_type=c12a7328-f81f-11d2-ba4b-00a0c93ec93b part type partuuid disk dir
    local -A labels=()
    own=$(findmnt -no SOURCE "$esp" 2>/dev/null || true)
    # firmware entries: "Boot0001* Name<TAB>HD(1,GPT,partuuid,...)/\EFI\...\file.efi", some
    # with the entry's own data after the path
    local line label uuid path tab=$'\t'
    local entry_re="^Boot[0-9A-Fa-f]{4}\\*? (.*)${tab}HD\\([0-9]+,GPT,([0-9a-fA-F-]+),[^)]*\\)/(.*\\.[eE][fF][iI])"
    while IFS= read -r line; do
        [[ $line =~ $entry_re ]] || continue
        label=${BASH_REMATCH[1]} uuid=${BASH_REMATCH[2],,} path=${BASH_REMATCH[3]//\\//}
        labels["$uuid|${path,,}"]=$label
    done < <(efibootmgr 2>/dev/null)

    mnt=$(mktemp -d /run/hyprdori-scan.XXXX)
    trap 'mountpoint -q "$mnt" && umount "$mnt"; rmdir "$mnt" 2>/dev/null || true' EXIT
    local found_any=false
    while read -r part type partuuid disk; do
        [[ ${type,,} == "$esp_type" ]] || continue
        [[ $(lsblk -dno TRAN "/dev/$disk" 2>/dev/null) == usb ]] && continue
        if [[ $part == "$own" ]]; then
            dir=$esp
        else
            mount -o ro "$part" "$mnt" 2>/dev/null || { echo "# $part: couldn't mount it, skipped" >&2; continue; }
            dir=$mnt
        fi
        local loaders=() sub file name
        while IFS= read -r sub; do
            case ${sub,,} in
                boot | linux) continue ;;
                limine | tools) [[ $dir == "$esp" ]] && continue ;;
            esac
            case ${sub,,} in
                microsoft) file=$(find "$dir/EFI/$sub" -maxdepth 2 -ipath '*/boot/bootmgfw.efi' | head -1) ;;
                systemd) file=$(find "$dir/EFI/$sub" -maxdepth 1 -iname 'systemd-boot*.efi' | head -1) ;;
                refind) file=$(find "$dir/EFI/$sub" -maxdepth 1 -iname 'refind_x64.efi' | head -1) ;;
                limine) file=$(find "$dir/EFI/$sub" -maxdepth 1 -iname '*.efi' | head -1) ;;
                *) file=$(find "$dir/EFI/$sub" -maxdepth 1 -iname 'shimx64.efi' | head -1)
                   [[ -n $file ]] || file=$(find "$dir/EFI/$sub" -maxdepth 1 -iname 'grubx64.efi' | head -1) ;;
            esac
            [[ -n $file ]] && loaders+=("${file#"$dir"}")
        done < <(find "$dir/EFI" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | sort)
        # nothing known on another system's ESP: its fallback loader
        if ((${#loaders[@]} == 0)) && [[ $dir != "$esp" ]]; then
            file=$(find "$dir/EFI" -maxdepth 2 -ipath '*/boot/bootx64.efi' 2>/dev/null | head -1)
            [[ -n $file ]] && loaders+=("${file#"$dir"}")
        fi
        local loader resource
        for loader in "${loaders[@]}"; do
            if [[ $dir == "$esp" ]]; then resource="boot():$loader"; else resource="guid($partuuid):$loader"; fi
            [[ -r $extra ]] && grep -qiF -- "$resource" "$extra" && continue
            name=${labels["${partuuid,,}|${loader,,}"]:-}
            if [[ -z $name ]]; then
                name=$(basename "$(dirname "$loader")")
                [[ ${name,,} == boot ]] && name=$(basename "$(dirname "$(dirname "$loader")")")
                [[ ${name,,} == microsoft ]] && name=Windows
                name=${name^}
            fi
            printf '# %s, on %s\n/%s\n    protocol: efi\n    path: %s\n\n' "${loader#/}" "$part" "$name" "$resource"
            found_any=true
        done
        [[ $dir == "$mnt" ]] && umount "$mnt"
    done < <(lsblk -rno PATH,PARTTYPE,PARTUUID,PKNAME)
    $found_any || echo "# No other systems' loaders found on the internal drives." >&2
    return 0
}
if [[ $mode == scan ]]; then
    scan
    exit 0
fi

if [[ $mode == install ]]; then
    if ((EUID != 0)) || [[ -z ${SUDO_USER:-} || $SUDO_USER == root ]]; then
        echo "Run through sudo from your own account: sudo $0" >&2
        exit 1
    fi
    home=$(getent passwd "$SUDO_USER" | cut -d: -f6)
    [[ -r /usr/share/limine/BOOTX64.EFI ]] || { echo "Install Limine first: pacman -S limine" >&2; exit 1; }
else
    home=$HOME
fi

# The current theme's colors, or Catppuccin's before hyprdori-theme-set has run
# shellcheck disable=SC2034  # every color colors.sh has, used below or not
background="#1e1e2e" selection="#45475a" muted="#585b70" foreground="#cdd6f4"
light_foreground="#bac2de" bright_foreground="#cdd6f4" accent="#89b4fa" magenta="#cba6f7"
red="#f38ba8" green="#a6e3a1" yellow="#fab387" blue="#89b4fa" cyan="#94e2d5"
bright_red="#f38ba8" bright_green="#a6e3a1" bright_yellow="#f9e2af" bright_blue="#89b4fa"
bright_magenta="#f5c2e7" bright_cyan="#94e2d5"
colors="$home/.config/theme/current/colors.sh"
if [[ -r $colors ]]; then
    # shellcheck source=/dev/null
    . "$colors"
elif $use_theme; then
    echo "No $colors; run hyprdori-theme-set first" >&2
    exit 1
fi
hex() { local c; for c; do printf '%s;' "${c#\#}"; done | sed 's/;$//'; }

# Kernel options: the running system's, without the initrd= the old loader added
if [[ ! -s /etc/kernel/cmdline ]]; then
    cmdline=$(sed -E 's/(^| )initrd=[^ ]*//g; s/  +/ /g; s/ $//' /proc/cmdline)
    if [[ $mode == install ]]; then
        echo "$cmdline" >/etc/kernel/cmdline
        echo "Wrote /etc/kernel/cmdline from the running system"
    fi
else
    cmdline=$(</etc/kernel/cmdline)
fi

found_kernels() {
    local k
    for k in linux linux-g14 linux-lts $(ls "$kernels" 2>/dev/null | sed -n 's/^vmlinuz-//p' | grep -vx 'linux\|linux-g14\|linux-lts'); do
        [[ -e $kernels/vmlinuz-$k && -e $kernels/initramfs-$k.img ]] && echo "$k"
    done
    return 0
}
mapfile -t found < <(found_kernels)
# Snapshots in the menu: a btrfs root with limine-snapper-sync (install.sh sets it up)
snapshots=false
[[ $(findmnt -no FSTYPE / 2>/dev/null) == btrfs ]] && command -v limine-snapper-sync >/dev/null && snapshots=true
((${#found[@]})) || { echo "No kernels with images in $kernels" >&2; exit 1; }

# This machine's other entries and menu options: above the first entry only the four options
# below, then entries (a /Name line, its indented options); comments and blank lines anywhere.
# Any other menu option would change the whole menu.
settings='timeout|quiet|remember_last_entry|default_entry'
if [[ -r $extra ]]; then
    bad=$(awk -v keys="^($settings):" '
        /^[[:space:]]*(#.*)?$/ { next }
        /^\/+[^\/[:space:]]/ { entry = 1; next }
        entry && /^[[:space:]]+[a-z_]+:/ { next }
        !entry && $0 ~ keys { next }
        { print NR ": " $0 }' "$extra")
    if [[ -n $bad ]]; then
        echo "$extra: above the first entry only ${settings//|/, }; then entries (/Name, then indented options):" >&2
        echo "$bad" >&2
        exit 1
    fi
fi
# A menu option from the file (above its first entry), or nothing; a note after it (# ...) and
# trailing spaces dropped, as Limine would read them as part of the value
setting() {
    [[ -r $extra ]] || return 0
    sed -n -E '/^\/+[^\/[:space:]]/q; s/^'"$1"':[[:space:]]*//p' "$extra" | tail -1 |
        sed -E 's/[[:space:]]*#.*$//; s/[[:space:]]+$//'
}
timeout=$(setting timeout) quiet=$(setting quiet) remember=$(setting remember_last_entry) default=$(setting default_entry)
# Values Limine reads only in these forms: anything else would quietly do something else
bad=
[[ -z $timeout || $timeout =~ ^([0-9]+(\.[0-9]+)?|no)$ ]] || bad+="  timeout: $timeout (seconds, or no)"$'\n'
[[ -z $quiet || $quiet =~ ^(yes|no)$ ]] || bad+="  quiet: $quiet (yes or no)"$'\n'
[[ -z $remember || $remember =~ ^(yes|no)$ ]] || bad+="  remember_last_entry: $remember (yes or no)"$'\n'
if [[ -n $bad ]]; then
    printf '%s: these menu options take only:\n%s' "$extra" "$bad" >&2
    exit 1
fi

# The resolution: given, or the first connected screen's native mode on the boot display's
# card (the one the firmware, and so Limine, draws on)
if [[ -z $resolution ]]; then
    for card in /sys/class/drm/card[0-9]; do
        [[ $(cat "$card/device/boot_vga" 2>/dev/null) == 1 ]] || continue
        for conn in "$card"-*; do
            [[ $(cat "$conn/status" 2>/dev/null) == connected ]] || continue
            resolution=$(head -1 "$conn/modes"); break 2
        done
    done
fi
[[ ${resolution:-} =~ ^([0-9]+)x([0-9]+)$ ]] || { echo "No resolution found; pass --resolution WxH" >&2; exit 1; }
res_w=${BASH_REMATCH[1]} res_h=${BASH_REMATCH[2]}

# Limine doubles its 8x16 font from 2560x1440 up. It centers the kernel tree on the screen; the
# logo goes just above it and the text logo near the bottom, above the countdown; both
# centered across the screen.
scale=1
((res_w >= 2560 && res_h >= 1440)) && scale=2
cell_h=$((16 * scale))
build=$(mktemp -d)
trap 'rm -rf "$build"' EXIT

wallpaper() {
    local logo_file text_file lw lh tw th tree_top logo_top text_top
    logo_file="$home/.config/theme/logo/dori-logo" text_file="$home/.config/theme/logo/dori-text"
    [[ -r $logo_file ]] || { echo "No logo at $logo_file" >&2; exit 1; }
    # drawn like kitty draws them, in 12px rows (24 on large screens), by hyprdori-logo-render
    "$here/../local/.local/bin/hyprdori-logo-render" --logo "$logo_file" --color "$magenta" --cell-height $((12 * scale)) --out "$build/logo.png"
    lw=$(magick identify -format %w "$build/logo.png"); lh=$(magick identify -format %h "$build/logo.png")
    # the tree's first row, as Limine centers it (the entries and "Arch Linux")
    tree_top=$(((res_h / cell_h - ${#found[@]} - 1) / 2 * cell_h))
    # the logo ending 2 rows above the tree
    logo_top=$((tree_top - 2 * cell_h - lh))
    ((logo_top < 0)) && logo_top=0
    local layers=("$build/logo.png" -geometry +$(((res_w - lw) / 2))+$logo_top -composite)
    if [[ -r $text_file ]]; then
        "$here/../local/.local/bin/hyprdori-logo-render" --logo "$text_file" --color "$magenta" --cell-height $((12 * scale)) --out "$build/text.png"
        tw=$(magick identify -format %w "$build/text.png"); th=$(magick identify -format %h "$build/text.png")
        # its bottom 4 rows from the screen's bottom, a row clear of the countdown line
        text_top=$((res_h - 4 * cell_h - th))
        layers+=("$build/text.png" -geometry +$(((res_w - tw) / 2))+$text_top -composite)
    fi
    magick -size "${res_w}x$res_h" "xc:$background" "${layers[@]}" "$1"
}

config() {
    if $plain; then
        cat <<EOF
# A plain Limine menu, written by Hyprdori's uninstall.sh (limine/install.sh --plain); edit it as
# any Limine menu: nothing of Hyprdori's writes it again unless Hyprdori is installed again and
# its menu chosen.
timeout: ${timeout:-3}
default_entry: ${default:-Arch Linux/${found[0]}}
${quiet:+quiet: $quiet
}${remember:+remember_last_entry: $remember
}
/+Arch Linux
EOF
    else
        cat <<EOF
# Written by limine/install.sh in Hyprdori; edit that and run it again.
# Options: $options
timeout: ${timeout:-3}
default_entry: ${default:-Arch Linux/${found[0]}}
${quiet:+quiet: $quiet
}${remember:+remember_last_entry: $remember
}terse: yes
interface_resolution: ${res_w}x$res_h
interface_branding:
interface_help_hidden: yes
interface_help_colour: $(hex "$accent")
interface_help_colour_bright: $(hex "$bright_foreground")
wallpaper: boot():/EFI/limine/wallpaper.png
wallpaper_style: centered
backdrop: $(hex "$background")
term_font_scale: ${scale}x$scale
term_background: ff$(hex "$background")
term_foreground: $(hex "$accent")
term_background_bright: $(hex "$selection")
term_foreground_bright: $(hex "$accent")
term_palette: $(hex "$selection" "$red" "$green" "$yellow" "$blue" "$magenta" "$cyan" "$light_foreground")
term_palette_bright: $(hex "$muted" "$bright_red" "$bright_green" "$bright_yellow" "$bright_blue" "$bright_magenta" "$bright_cyan" "$bright_foreground")
term_margin: 0
term_margin_gradient: 0

/+Arch Linux
EOF
    fi
    # limine-snapper-sync finds this entry by the machine's id
    $snapshots && echo "    comment: machine-id=$(cat /etc/machine-id)"
    local k
    for k in "${found[@]}"; do
        cat <<EOF
//$k
    protocol: linux
    kernel_path: boot():/${kernels#"$esp"/}/vmlinuz-$k
    module_path: boot():/${kernels#"$esp"/}/initramfs-$k.img
    kernel_cmdline: $cmdline
EOF
    done
    # where limine-snapper-sync puts an entry per snapshot
    $snapshots && echo "//Snapshots"
    if [[ -r $extra ]] && grep -q '^/' "$extra"; then
        printf '\n# Other systems, from %s\n' "$extra"
        sed -n -E '/^\/+[^\/[:space:]]/,$p' "$extra"
    fi
    return 0
}

if [[ $mode == print ]]; then
    config
    exit 0
fi
if [[ $mode == preview ]]; then
    wallpaper "$preview"
    echo "Preview: $preview"
    exit 0
fi

conf=$(config)
$plain || wallpaper "$build/wallpaper.png"
install -D -m 0644 /usr/share/limine/BOOTX64.EFI "$esp/EFI/limine/BOOTX64.EFI"
# The same at the path firmware starts when it has no boot entries (lost to a firmware update or
# reset, or another system's install). Only where nothing else is there: another system's own
# fallback loader on this ESP stays.
fallback="$esp/EFI/BOOT/BOOTX64.EFI"
if [[ ! -e $fallback ]] || grep -qa 'Limine' "$fallback"; then
    install -D -m 0644 /usr/share/limine/BOOTX64.EFI "$fallback"
    rm -f "$esp/EFI/BOOT/limine.conf"
else
    echo "$fallback is another loader's; left as it is" >&2
fi
if $plain; then
    rm -f "$esp/EFI/limine/wallpaper.png"
else
    install -m 0644 "$build/wallpaper.png" "$esp/EFI/limine/"
fi
printf '%s\n' "$conf" >"$esp/limine.conf"
# Limine reads the one next to its EFI file first: none there, so it reads /efi/limine.conf
rm -f "$esp/EFI/limine/limine.conf"
if $snapshots; then
    limine-snapper-sync >/dev/null 2>&1 && echo "Snapshot entries added (limine-snapper-sync)" ||
        echo "limine-snapper-sync couldn't add the snapshot entries; they come with the next snapshot" >&2
fi

# A firmware boot entry, first in the boot order, made once
if ! efibootmgr | grep -q '\\EFI\\limine\\BOOTX64.EFI'; then
    part=$(findmnt -no SOURCE "$esp")
    efibootmgr --create --disk "/dev/$(lsblk -no PKNAME "$part")" \
        --part "$(<"/sys/class/block/${part#/dev/}/partition")" \
        --label "Limine" --loader '\EFI\limine\BOOTX64.EFI' --unicode >/dev/null
    echo "Added the Limine boot entry, first in the boot order"
fi
echo "Installed. Limine shows at the next boot."
