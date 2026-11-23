#!/usr/bin/env bash
# Removes Hyprdori from this machine: what install.sh changed, read back from its record
# (/etc/hyprdori/install.log), and Hyprdori's own files where they're known by name. The boot
# menu stays bootable: Limine keeps a plain menu, or goes when another boot loader is there and
# removing it is chosen. The packages install.sh added are offered for removal, never removed
# without asking. Left as they are: pacman.conf's repos and the mirrors (their .bak files are
# the originals), the general services (network, bluetooth, ...), the GPU drivers in the
# initramfs, apps' own plugins (Neovim, zsh, yazi) and GNOME settings (fonts, cursor, icons).
#
#   ~/.src/hyprdori/uninstall.sh
#   curl -fsSL https://raw.githubusercontent.com/kuvk/hyprdori/main/uninstall.sh | bash
#   uninstall.sh --dry-run     what it would do; nothing changed, no password

# -h, --help: the comment above, then nothing else runs
case ${1:-} in -h | --help) awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; exit 0 ;; esac
set -uo pipefail

main() {
    # Through a pipe (curl ... | bash): the clone's own copy runs, with the terminal for questions
    if [[ ! -f ${BASH_SOURCE[0]:-} ]]; then
        local clone
        clone=$(readlink -f "$HOME/.local/bin/hyprdori" 2>/dev/null) && clone=${clone%/local/.local/bin/hyprdori}
        [[ -x ${clone:-}/uninstall.sh ]] || clone=$HOME/.src/hyprdori
        [[ -x $clone/uninstall.sh ]] || { echo "hyprdori: no clone of Hyprdori found (~/.src/hyprdori)" >&2; exit 1; }
        if { : </dev/tty; } 2>/dev/null; then exec "$clone/uninstall.sh" "$@" </dev/tty; fi
        exec "$clone/uninstall.sh" "$@" </dev/null
    fi
    uninstall "$@"
}

uninstall() {
    local dry=false
    [[ ${1:-} == --dry-run ]] && dry=true
    hyprdori=$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")
    # the repo's commands by their own path: the links in ~/.local/bin go during this
    bin=$hyprdori/local/.local/bin
    ledger=/etc/hyprdori/install.log
    ((EUID != 0)) || { echo "Run this as yourself, not root: it asks for sudo when needed." >&2; exit 1; }

    step() { printf '\n\e[1;34m==> %s\e[0m\n' "$1"; }
    note() { printf '\e[33m%s\e[0m\n' "$1"; }
    ask() {
        local answer hint="[y/N]"
        [[ $2 == y ]] && hint="[Y/n]"
        if ! { : </dev/tty; } 2>/dev/null; then
            echo "$1 $hint $2"
            [[ $2 == y ]]
            return
        fi
        read -r -p "$1 $hint " answer </dev/tty
        [[ ${answer:-$2} =~ ^[yY] ]]
    }
    # A change: printed in a dry run, made otherwise
    run() {
        if $dry; then
            printf '  would: %s\n' "$*"
        else
            "$@"
        fi
    }
    # The record's lines of one kind, newest first, without the date: "backup PATH BACKUP" gives
    # "PATH BACKUP"
    logged() { [[ -r $ledger ]] && tac "$ledger" | awk -v kind="$1" '$2 == kind { $1 = ""; $2 = ""; sub(/^ +/, ""); print }'; }
    installed() { "$bin/hyprdori-installed" "$1"; }
    have_record=false
    [[ -r $ledger ]] && have_record=true

    # --- What's here ----------------------------------------------------------------------------
    local menu=false splash=false login=false others=()
    installed menu && menu=true
    installed splash && splash=true
    installed login && login=true
    # boot loaders other than Limine, which could boot the machine without it
    [[ -e /boot/grub/grub.cfg ]] && others+=(GRUB)
    for dir in /efi /boot /boot/efi; do
        mountpoint -q "$dir" || continue
        { [[ -e $dir/EFI/systemd/systemd-bootx64.efi ]] || sudo -n test -e "$dir/EFI/systemd/systemd-bootx64.efi"; } 2>/dev/null && others+=(systemd-boot)
        { [[ -e $dir/EFI/refind/refind_x64.efi ]] || sudo -n test -e "$dir/EFI/refind/refind_x64.efi"; } 2>/dev/null && others+=(rEFInd)
    done
    mapfile -t others < <(printf '%s\n' "${others[@]}" | sed '/^$/d' | sort -u)

    cat <<MSG
This removes Hyprdori from this machine:
  the links into the repo, and the files moved out of their way put back
  the boot menu's look$($menu && echo " (Limine: a plain menu, or removed if another boot loader boots this machine)")
  $($splash && echo "the boot splash (Plymouth's hook and theme), the initramfs built again" || echo "no boot splash of Hyprdori's here")
  $($login && echo "the login screen's look and settings (SDDM's own come back)" || echo "no login screen of Hyprdori's here")
  Hyprdori's system files (logind's lock delay, the browsers' color policy, /var/lib/hyprdori, /etc/hyprdori)
  then it offers to remove $($have_record && echo "the packages install.sh added" || echo "nothing more: no record of what install.sh added")
MSG
    if $dry; then
        echo "(A dry run: nothing is changed; the questions below take their defaults without a terminal.)"
    else
        ask "Remove Hyprdori?" n || { echo "Nothing changed."; exit 0; }
    fi
    if ! $dry; then
        "$bin/hyprdori-awake" $$ "the removal" || { echo "Nothing changed."; exit 0; }
        "$bin/hyprdori-sudo-hold" $$ || { echo "No password, nothing changed." >&2; exit 1; }
    fi
    local rebuild=false
    local -a removed_options=()

    # --- Boot menu ------------------------------------------------------------------------------
    local remove_limine=false
    if $menu; then
        step "Boot menu"
        if ((${#others[@]})); then
            ask "Remove Limine too? ${others[*]} then boots this machine (its own menu must list the kernels, which go back to /boot)" n &&
                remove_limine=true
        fi
    fi

    # --- Splash -----------------------------------------------------------------------------------
    local splash_options=(splash initramfs_async=0 systemd.tty.term.console=dumb rd.luks.options=timeout=90s,tries=3 systemd.default_device_timeout_sec=infinity)
    if $splash; then
        step "Boot splash"
        run sudo sed -i -E '/^HOOKS=/{s/ plymouth\b//; s/ luks-poweroff\b//}' /etc/mkinitcpio.conf
        run sudo rm -f /etc/initcpio/install/luks-poweroff
        run sudo rm -rf /usr/share/plymouth/themes/hyprdori /etc/systemd/system/plymouth-quit.service.d/hyprdori.conf
        [[ -f /etc/plymouth/plymouthd.conf ]] && run sudo sed -i '/^Theme=hyprdori$/d' /etc/plymouth/plymouthd.conf
        rebuild=true
        if ! $menu; then
            note "Remove the splash's kernel options from the boot loader's own, where they were added: ${splash_options[*]}"
        fi
    fi
    # The kernel options install.sh added to Limine's (its record), or without a record the
    # splash's, which mean nothing without it
    if $menu && [[ -s /etc/kernel/cmdline ]]; then
        local cmdline option
        cmdline=" $(cat /etc/kernel/cmdline) "
        if $have_record; then
            mapfile -t removed_options < <(logged kernel-option)
        elif $splash; then
            removed_options=("${splash_options[@]}")
        fi
        for option in "${removed_options[@]}"; do cmdline=${cmdline// "$option" / }; done
        cmdline=$(echo "$cmdline" | xargs)
        if [[ $cmdline != "$(cat /etc/kernel/cmdline)" ]]; then
            echo "Kernel options: $cmdline"
            run sudo sh -c 'printf "%s\n" "$1" >/etc/kernel/cmdline' _ "$cmdline"
        fi
    fi

    # --- Login screen -----------------------------------------------------------------------------
    if $login; then
        step "Login screen"
        run sudo rm -f /etc/sddm.conf.d/hyprdori.conf /etc/sddm.conf.d/autologin.conf "/usr/share/sddm/faces/$USER.face.icon"
        run sudo rm -rf /usr/share/sddm/themes/hyprdori /usr/share/sddm/hypr/cursors/hyprdori-startup
        if [[ -f /usr/share/sddm/hypr/hyprland.lua.bak ]]; then
            run sudo mv /usr/share/sddm/hypr/hyprland.lua.bak /usr/share/sddm/hypr/hyprland.lua
        else
            run sudo rm -f /usr/share/sddm/hypr/hyprland.lua
        fi
        grep -qsE '^# Local SDDM settings' /etc/sddm.conf && run sudo rm -f /etc/sddm.conf
        # the settings files sddm/install.sh set aside, oldest first, where their place is free
        local set_aside file
        for set_aside in /etc/sddm.hyprdori-backup/*/; do
            [[ -d $set_aside ]] || continue
            for file in "$set_aside"* "$set_aside".[!.]*; do
                [[ -e $file ]] || continue
                if [[ ${file##*/} == sddm.conf ]]; then
                    [[ -e /etc/sddm.conf ]] || run sudo mv "$file" /etc/sddm.conf
                else
                    [[ -e /etc/sddm.conf.d/${file##*/} ]] || run sudo mv "$file" /etc/sddm.conf.d/
                fi
            done
        done
        [[ -d /etc/sddm.hyprdori-backup ]] && run sudo rm -rf /etc/sddm.hyprdori-backup
        # the login screen SDDM took the place of comes back
        local unit
        while read -r unit; do
            [[ -n $unit ]] || continue
            run sudo systemctl disable sddm.service
            run sudo systemctl enable "$unit"
            echo "$unit is the login screen again"
        done < <(logged disable | head -1)
        logged disable | grep -q . || note "SDDM stays the login screen, in its own look (removing the sddm package, offered below, leaves the console)."
    fi

    # --- Hyprdori's other system files ------------------------------------------------------------
    step "System files"
    grep -qs '^InhibitDelayMaxSec=15$' /etc/systemd/logind.conf.d/20-inhibit-delay.conf &&
        run sudo rm -f /etc/systemd/logind.conf.d/20-inhibit-delay.conf
    if [[ -e /usr/local/bin/browser-theme-policy ]]; then
        run sudo "$bin/hyprdori-browser-theme-setup" --remove
    fi
    # The boot menu: plain, or gone with the kernels back in /boot
    if $menu && $remove_limine; then
        local preset base modules
        for preset in /etc/mkinitcpio.d/*.preset.bak; do
            [[ -e $preset ]] && run sudo mv "$preset" "${preset%.bak}"
        done
        for modules in /usr/lib/modules/*/pkgbase; do
            base=$(<"$modules")
            run sudo install -m 0644 "${modules%/pkgbase}/vmlinuz" "/boot/vmlinuz-$base"
        done
        local entry
        entry=$(efibootmgr 2>/dev/null | sed -n -E 's/^Boot([0-9A-Fa-f]{4})\*? .*\\EFI\\limine\\BOOTX64\.EFI.*/\1/Ip' | head -1)
        [[ -n $entry ]] && run sudo efibootmgr -q -b "$entry" -B
        run sudo rm -rf /efi/EFI/limine /efi/limine.conf
        sudo -n grep -qsa Limine /efi/EFI/BOOT/BOOTX64.EFI && run sudo rm -f /efi/EFI/BOOT/BOOTX64.EFI
        run sudo rm -f /etc/default/limine /etc/mkinitcpio.conf.d/snapshots.conf
        systemctl is-enabled -q limine-snapper-sync.service 2>/dev/null && run sudo systemctl disable limine-snapper-sync.service
        rebuild=true
    fi
    if $rebuild; then
        echo "Building the initramfs again"
        run sudo mkinitcpio -P
    fi
    if $menu && $remove_limine; then
        run sudo rm -rf /efi/arch
        note "Limine is gone: check that ${others[*]}'s menu lists the kernels in /boot before rebooting."
    elif $menu; then
        run sudo "$hyprdori/limine/install.sh" --plain
    fi
    if sudo -n snapper list-configs 2>/dev/null | grep -q '^root '; then
        ask "Keep the snapshots of / (snapper's root config and its snapshots)?" y ||
            run sudo snapper -c root delete-config
    fi
    run sudo rm -rf /var/lib/hyprdori

    # --- The home folder --------------------------------------------------------------------------
    step "Home folder"
    run systemctl --user disable --now hyprdori-update-check.timer
    # Theme files rendered outside the repo, where they're still what the theme made
    local rendered
    while IFS= read -r rendered; do
        run rm -f "$rendered"
    done < <(PYTHONDONTWRITEBYTECODE=1 python3 -I - "$hyprdori" <<'PY'
import sys
from pathlib import Path
repo = Path(sys.argv[1]).resolve()
sys.path.insert(0, str(repo / "local/.local/lib/hyprdori"))
try:
    import theme_render
except Exception:
    sys.exit()
current = Path.home() / ".config/theme/current"
for name, dests in theme_render.EXTRA_DESTINATIONS.items():
    for dest in dests if isinstance(dests, list) else [dests]:
        real = dest.resolve()
        if str(dest).startswith("/var/lib/") or real.is_relative_to(repo) or not real.is_file():
            continue
        made = current / name
        if made.is_file() and made.read_bytes() == real.read_bytes():
            print(dest)
starship = Path.home() / ".config/starship.toml"
if starship.is_file() and (Path.home() / ".config/starship/base.toml").resolve().is_relative_to(repo):
    print(starship)
PY
)
    # The links
    local not_stowed=(docs limine migrations packages plymouth sddm) packages=() dir name
    for dir in "$hyprdori"/*/; do
        name=$(basename "$dir")
        [[ " ${not_stowed[*]} " == *" $name "* ]] || packages+=("$name")
    done
    run stow -D -d "$hyprdori" -t "$HOME" "${packages[@]}"
    echo "Unlinked: ${packages[*]}"
    # Files that were in the way of the links, back where they were (oldest first: the ones
    # from before Hyprdori), where nothing is in their place
    local backups=() back rel
    for back in "$HOME"/.hyprdori-backup/*/; do [[ -d $back ]] && backups+=("${back%/}"); done
    if ((${#backups[@]})) && ask "Put back the files moved out of the links' way (${#backups[@]} backup(s) in ~/.hyprdori-backup)?" y; then
        for back in "${backups[@]}"; do
            while IFS= read -r -d '' rel; do
                [[ -e $HOME/$rel || -L $HOME/$rel ]] && continue
                run mkdir -p "$(dirname "$HOME/$rel")"
                run mv "$back/$rel" "$HOME/$rel"
            done < <(cd "$back" && find . \( -type f -o -type l \) -printf '%P\0')
        done
        run find "$HOME/.hyprdori-backup" -depth -type d -empty -delete
    fi
    # What opens what, when install.sh made the file and it's still as it was
    if logged file | grep -qx "$HOME/.config/mimeapps.list" && cmp -s "$HOME/.config/mimeapps.list" "$hyprdori/packages/mimeapps.list"; then
        run rm -f "$HOME/.config/mimeapps.list"
    fi
    # The login shell from before
    local shell
    shell=$(logged shell | tail -1)
    [[ -z $shell && $(getent passwd "$USER" | cut -d: -f7) == */zsh ]] &&
        ask "Login shell back to bash?" y && shell=/bin/bash
    [[ -n $shell ]] && run sudo chsh -s "$shell" "$USER"
    if ask "Delete Hyprdori's settings and state too (~/.config/hyprdori, ~/.local/state/hyprdori, the shell's settings, the wallpaper choice)? Wallpapers in ~/.local/share/hyprdori stay" n; then
        run rm -rf "$HOME/.config/hyprdori" "$HOME/.local/state/hyprdori" "$HOME/.local/state/quickshell" "$HOME/.local/state/wallpaper"
    fi

    # --- Packages ---------------------------------------------------------------------------------
    step "Packages"
    if $have_record; then
        local pkgs=() apps=() pkg
        while read -r pkg; do pacman -Q "$pkg" &>/dev/null && pkgs+=("$pkg"); done < <(logged package | sort -u)
        if ((${#pkgs[@]})); then
            echo "install.sh added ${#pkgs[@]} package(s) still installed; pacman lists them and asks (n keeps them all):"
            run sudo pacman -Rnsu "${pkgs[@]}" || note "Kept the packages."
        else
            echo "None of the packages install.sh added is installed."
        fi
        while read -r pkg; do flatpak info "$pkg" &>/dev/null && apps+=("$pkg"); done < <(logged flatpak | sort -u)
        if ((${#apps[@]})) && ask "Remove the Flathub apps install.sh added (${apps[*]})?" n; then
            run sudo flatpak uninstall -y "${apps[@]}"
        fi
    else
        echo "No record of what install.sh added (it was installed before the record was kept): packages/*.txt lists what it installs."
    fi
    run sudo rm -rf /etc/hyprdori

    # --- The clone --------------------------------------------------------------------------------
    step "Done"
    if ask "Delete the clone too ($hyprdori)?" n; then
        run rm -rf "$hyprdori"
    else
        echo "The clone stays in $hyprdori; install.sh there installs Hyprdori again."
    fi
    $dry && echo "Nothing was changed (a dry run)." || echo "Reboot to finish."
}

main "$@"
