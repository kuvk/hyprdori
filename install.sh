#!/usr/bin/env bash
# Sets up Hyprdori on an Arch install. Run it as the user, not root (it asks for sudo) after the
# first boot, from a console or any session, with the network up; boot.sh clones the repo to
# ~/.src/hyprdori and runs it:
#
#   curl -fsSL https://raw.githubusercontent.com/kuvk/hyprdori/main/boot.sh | bash
#
# Expects only what packages/base.txt lists, and a user with sudo. Any boot loader, login
# screen, file system and drive layout, encrypted or not: Hyprdori's boot menu (Limine), boot
# splash (Plymouth) and login screen (SDDM) are each asked about, on by default where nothing
# else is in their place. Safe to run again: each step skips what's already done. What it
# changes outside the home folder and what it installs is written to /etc/hyprdori/install.log,
# which uninstall.sh reads.
#
# Steps: pacman.conf (multilib, the g14 repo on ASUS laptops), mirrors (reflector), config links
# (stow; files in the way go to ~/.hyprdori-backup), packages (packages/*.txt by detected
# hardware and answers), Flatpak, services, zsh and its plugins, the theme (and the login screen,
# with autologin if chosen), snapshots on a btrfs root (snapper), then boot: the initramfs, the
# splash, the menu and its kernel options.
#
#   install.sh --dry-run   what an install would do on this machine, and nothing done: the same
#                          questions (their defaults, when not run in a terminal), then the
#                          hardware found, the packages not installed yet, the files in the way of
#                          the links, the services and what the boot step would find. No password.
set -euo pipefail
dry=false
[[ ${1:-} == --dry-run ]] && dry=true

hyprdori=$(dirname "$(readlink -f "$0")")
# Not stowed; hyprdori-update's Links step has the same list (hyprdori-check compares them)
not_stowed=(docs limine migrations packages plymouth sddm)
packages=()
for dir in "$hyprdori"/*/; do
    name=$(basename "$dir")
    [[ " ${not_stowed[*]} " == *" $name "* ]] || packages+=("$name")
done

step() { printf '\n\e[1;34m==> %s\e[0m\n' "$1"; }
note() { printf '\e[33m%s\e[0m\n' "$1"; }
# ask "question" y|n: the default is what Enter picks
ask() {
    local answer hint="[y/N]"
    [[ $2 == y ]] && hint="[Y/n]"
    if $dry && [[ ! -t 0 ]]; then
        echo "$1 $hint $2"
        [[ $2 == y ]]
        return
    fi
    read -r -p "$1 $hint " answer </dev/tty
    [[ ${answer:-$2} =~ ^[yY] ]]
}
# Package names from a list: comments and blank lines dropped
list() { sed 's/#.*//; s/[[:space:]]//g; /^$/d' "$hyprdori/packages/$1.txt"; }
# A Flathub app ID (com.example.App: two dots or more), as against a package's name
is_flathub() { [[ $1 =~ ^[A-Za-z][A-Za-z0-9_-]*(\.[A-Za-z0-9_-]+){2,}$ ]]; }
# Files where a link should go, which aren't links into Hyprdori already: their paths under the
# home folder, each ended by a NUL
in_the_way() {
    local name file rel target
    for name in "${packages[@]}"; do
        while IFS= read -r -d '' file; do
            rel=${file#"$hyprdori/$name/"}
            target="$HOME/$rel"
            [[ -e $target || -L $target ]] || continue
            [[ $(readlink -f "$target") == "$file" ]] && continue
            printf '%s\0' "$rel"
        done < <(find "$hyprdori/$name" \( -type f -o -type l \) -print0)
    done
}
# Every package of the chosen lists, once each. A list may name Flathub apps next to packages
# (gaming.txt): those are wanted_flatpaks'
wanted_packages() {
    local name
    {
        for group in "${groups[@]}"; do
            while read -r name; do is_flathub "$name" || echo "$name"; done < <(list "$group")
        done
        boot_packages
    } | sort -u
}
# The packages the config can't do without: core.txt and the lists the hardware picked (the GPU's
# driver, a virtual machine's agent). Without one of them the install stops after the packages;
# the lists that were asked about (apps, gaming, ...) only say what failed.
needed_lists=(core guest nvidia intel amd hybrid)
needed_packages() {
    local group name
    {
        for group in "${groups[@]}"; do
            [[ " ${needed_lists[*]} " == *" $group "* ]] || continue
            while read -r name; do is_flathub "$name" || echo "$name"; done < <(list "$group")
        done
        boot_packages needed
    } | sort -u
}
# The packages of the chosen boot parts (packages/boot.txt): a section names a part, or parts
# joined by "+" that must all be chosen. With "needed", only the one-part sections: a part's own
# packages, without which the install stops
boot_packages() {
    local chosen=" ${parts[*]} " section= line name part ok need=()
    while IFS= read -r line; do
        line=${line%%#*}
        if [[ $line =~ ^\[([a-z+]+)\] ]]; then
            section=${BASH_REMATCH[1]}
            continue
        fi
        name=${line//[[:space:]]/}
        [[ -n $name && -n $section ]] || continue
        [[ ${1:-} == needed && $section == *+* ]] && continue
        ok=true
        IFS=+ read -ra need <<<"$section"
        for part in "${need[@]}"; do [[ $chosen == *" $part "* ]] || ok=false; done
        $ok && echo "$name"
    done <"$hyprdori/packages/boot.txt"
    return 0
}
# What this changes outside the home folder, and what it installs, a line each, so uninstall.sh
# undoes exactly that (and offers to remove exactly those packages)
ledger=/etc/hyprdori/install.log
record() {
    $dry && return 0
    printf '%s %s\n' "$(date +%F)" "$*" | sudo tee -a "$ledger" >/dev/null
}
# A file on the ESP or in /boot, which may be readable by root only
on_esp() { [[ -e $1 ]] || { ! $dry && sudo test -e "$1"; } 2>/dev/null; }
# Every Flathub app: flatpak.txt if chosen, and the ones in the chosen lists
wanted_flatpaks() {
    local name
    {
        $flatpak && list flatpak
        for group in "${groups[@]}"; do
            while read -r name; do is_flathub "$name" && echo "$name"; done < <(list "$group")
        done
    } | sort -u
}
# The system services enabled for the chosen lists
services_for() {
    local services=(NetworkManager bluetooth power-profiles-daemon fstrim.timer)
    [[ $login == sddm ]] && services+=(sddm)
    if [[ " ${groups[*]} " == *" nvidia "* ]]; then
        services+=(nvidia-suspend nvidia-hibernate nvidia-resume)
        $laptop && services+=(nvidia-powerd)
    fi
    [[ " ${groups[*]} " == *" desktop "* ]] && services+=(coolercontrold)
    $guest && services+=(qemu-guest-agent spice-vdagentd)
    [[ " ${groups[*]} " == *" vm "* ]] && services+=(libvirtd docker.socket)
    printf '%s\n' "${services[@]}"
}
# --dry-run: what the steps below would find and do, from what was answered; nothing is changed
dry_report() {
    local names=() missing=() rel
    step "Hardware"
    echo "Graphics: ${gpus[*]:-none found}; the boot screen's: ${boot_gpu:-unknown}${boot_driver:+ ($boot_driver)}"
    echo "Laptop: $laptop; ASUS laptop: $asus_laptop; virtual machine: $guest"
    echo "Root: $(findmnt -no FSTYPE /); encrypted drives in the initramfs: $encrypted"
    step "pacman.conf"
    grep -q '^#\[multilib\]$' /etc/pacman.conf && echo "multilib would be turned on" || echo "multilib is on already"
    if [[ " ${groups[*]} " == *" laptop "* ]]; then
        grep -q '^\[g14\]' /etc/pacman.conf && echo "The g14 repo is there already" || echo "The g14 repo and its keys would be added"
    fi
    step "Mirrors"
    [[ -f /etc/pacman.d/mirrorlist.bak ]] && echo "Ranked before; left as they are" || echo "Would be ranked with reflector"
    step "Links"
    echo "Would link: ${packages[*]}"
    while IFS= read -r -d '' rel; do names+=("$rel"); done < <(in_the_way)
    if ((${#names[@]})); then
        echo "${#names[@]} file(s) in the way would move to ~/.hyprdori-backup:"
        printf '  ~/%s\n' "${names[@]}"
    else
        echo "Nothing in the way."
    fi
    step "Packages"
    command -v paru >/dev/null || echo "paru would be built from the AUR"
    mapfile -t names < <(wanted_packages)
    mapfile -t missing < <(comm -23 <(printf '%s\n' "${names[@]}") <(pacman -Qq | sort -u))
    echo "${#names[@]} in the chosen lists, ${#missing[@]} not installed${missing:+:}"
    ((${#missing[@]})) && printf '%s\n' "${missing[@]}" | column -c "$(tput cols 2>/dev/null || echo 100)" | sed 's/^/  /'
    mapfile -t missing < <(comm -12 <(printf '%s\n' "${missing[@]}") <(needed_packages))
    ((${#missing[@]})) && echo "Needed (the install stops after the packages while one is missing): ${missing[*]}"
    mapfile -t names < <(wanted_flatpaks)
    if ((${#names[@]})); then
        step "Flatpak"
        echo "Would install from Flathub: ${names[*]}"
    fi
    step "Services"
    mapfile -t names < <(services_for)
    echo "Would enable: ${names[*]}, and the weekly update check"
    [[ $login == sddm && -n $dm && $dm != sddm ]] && echo "Would turn off $dm (SDDM takes its place)"
    step "Snapshots"
    if $snapshots; then
        echo "snapper for /, the newest 5 update snapshots kept$($menu && echo ", in the boot menu")"
    else
        echo "None."
    fi
    step "Boot"
    echo "ESP: ${esp_at:-none found}; other boot loaders: ${other_loaders[*]:-none found}; login screen: ${dm:-none}"
    echo "Login screen: $(case $login in sddm) echo "Hyprdori's (SDDM)" ;; kept) echo "$dm, as it is" ;; *) echo "none (Hyprland started from the console)" ;; esac)"
    echo "Boot splash: $($splash && echo "Plymouth, its hook in the initramfs" || echo none)"
    if $menu; then
        echo "Boot menu: Limine, kernels and images moved to /efi/arch, the kernel options in /etc/kernel/cmdline"
        [[ -e /etc/hyprdori/limine-entries.conf ]] ||
            echo "Would make /etc/hyprdori/limine-entries.conf (other systems' boot entries; only comments)"
    else
        echo "Boot menu: left as it is${other_loaders:+ (${other_loaders[*]})}$($splash && echo "; the splash's kernel options are printed, to add to it")"
    fi
    echo
    echo "Nothing was changed."
}

# --- Checks -------------------------------------------------------------------------------------
((EUID != 0)) || { echo "Run this as yourself, not root: it asks for sudo when needed." >&2; exit 1; }
[[ -f /etc/arch-release ]] || { echo "This is for Arch Linux." >&2; exit 1; }
missing=()
while read -r pkg; do pacman -Q "$pkg" &>/dev/null || missing+=("$pkg"); done < <(list base)
if ((${#missing[@]})); then
    echo "The Arch install is missing ${missing[*]} (packages/base.txt): sudo pacman -S ${missing[*]}, then run this again." >&2
    exit 1
fi
curl -fsI --max-time 10 https://archlinux.org >/dev/null || { echo "No internet connection." >&2; exit 1; }
# awake while it runs (on battery it asks first), then the password once: sudo keeps it until
# the install ends, however long the downloads take
if ! $dry; then
    "$hyprdori/local/.local/bin/hyprdori-awake" $$ "the install" || { echo "Nothing installed."; exit 0; }
    export HYPRDORI_AWAKE_ASKED=1
    "$hyprdori/local/.local/bin/hyprdori-sudo-hold" $$ || { echo "No password, nothing installed." >&2; exit 1; }
    sudo install -d -m 0755 /etc/hyprdori
fi
# What's installed before, so the record names only what this run adds
before=$(mktemp)
pacman -Qq | sort >"$before"
flatpaks_before=$(mktemp)
command -v flatpak >/dev/null && flatpak list --app --columns=application 2>/dev/null | sort >"$flatpaks_before"
trap 'rm -f "$before" "$flatpaks_before"' EXIT

# --- Hardware -----------------------------------------------------------------------------------
# hyprdori-hw answers what the machine is (from the repo: nothing is linked yet)
hw=$hyprdori/local/.local/bin/hyprdori-hw
gpus=() boot_gpu= boot_driver=
mapfile -t gpus < <("$hw" gpus)
read -r boot_gpu boot_driver < <("$hw" boot-gpu) || true
has_gpu() { [[ " ${gpus[*]} " == *" $1 "* ]]; }
laptop=false asus_laptop=false
"$hw" laptop && laptop=true
"$hw" asus && asus_laptop=true
# Inside a virtual machine (a test install): its GPU's Vulkan, the guest agent, Spice's clipboard
# daemon (spice-vdagentd, enabled too in case udev doesn't start it), and no for the questions
# about real hardware and running VMs
guest=false
"$hw" vm && guest=true

groups=(core)
$guest && groups+=(guest)
has_gpu 0x10de && groups+=(nvidia)
has_gpu 0x8086 && groups+=(intel)
has_gpu 0x1002 && groups+=(amd)
# NVIDIA next to another GPU in a laptop: prime-run
"$hw" hybrid && groups+=(hybrid)
# Both asked on every machine, as not every laptop or desktop needs them; what the hardware
# suggests is the default
if ask "ASUS laptop: the g14 repo, asusctl and ROG Control Center (packages/laptop.txt)?" "$($asus_laptop && echo y || echo n)"; then
    groups+=(laptop)
fi
if ask "Desktop PC: fan, pump and RGB control: CoolerControl, liquidctl, OpenRGB (packages/desktop.txt)?" "$($laptop || $guest && echo n || echo y)"; then
    groups+=(desktop)
fi
ask "Apps with window rules (packages/apps.txt)?" y && groups+=(apps)
if ask "Gaming: Steam, Lutris, Gamescope, ProtonUp-Qt, and Heroic from Flathub (packages/gaming.txt)?" "$($guest && echo n || echo y)"; then
    groups+=(gaming)
fi
if ask "Virtual machines and Docker (packages/vm.txt)?" "$($guest && echo n || echo y)"; then
    groups+=(vm)
    has_gpu 0x10de && groups+=(nvidia-docker)
fi
flatpak=false
ask "Flatpak apps (packages/flatpak.txt)?" y && flatpak=true
# The browsers' own text (tabs, address bar, menus): the font everything else uses, or always the
# display font, so a later Monospace everywhere (Settings > Fonts) leaves them alone, a monospace
# font being wide there. hyprdori-browser-theme-setup --follow-font true|false changes it later.
browser_font=true
ask "Browsers: should their tabs, address bar and menus follow the font everything else uses (also monospace, if you turn that on)?" y ||
browser_font=false
# The boot menu, splash and login screen (packages/boot.txt): each only when chosen, and kept
# once set up (uninstall.sh removes them). What's there already picks the defaults
installed() { "$hyprdori/local/.local/bin/hyprdori-installed" "$1"; }
# the ESP (Hyprdori's menu and its kernels go on the one at /efi)
esp_at=
for dir in /efi /boot /boot/efi; do
    [[ $(findmnt -no FSTYPE "$dir" 2>/dev/null) == vfat ]] && { esp_at=$dir; break; }
done
# other boot loaders, by what they leave on the ESP or in /boot; a Limine set up otherwise keeps
# its own menu. Two Limine menus are Hyprdori's to replace: the first-boot one from the install
# guide (docs/arch-install.md) and uninstall.sh's plain one, each saying so in its first lines
other_loaders=() own_limine=false
replaceable='install.sh replaces this menu|limine/install.sh --plain'
for dir in /efi /boot /boot/efi; do
    mountpoint -q "$dir" || continue
    on_esp "$dir/EFI/systemd/systemd-bootx64.efi" && other_loaders+=(systemd-boot)
    on_esp "$dir/EFI/refind/refind_x64.efi" && other_loaders+=(rEFInd)
    if ! installed menu; then
        for file in limine.conf limine/limine.conf EFI/limine/limine.conf EFI/BOOT/limine.conf; do
            on_esp "$dir/$file" || continue
            { grep -qsE "$replaceable" "$dir/$file" || { ! $dry && sudo grep -qsE "$replaceable" "$dir/$file"; }; } ||
                own_limine=true
        done
    fi
done
[[ -e /boot/grub/grub.cfg ]] && other_loaders+=(GRUB)
$own_limine && other_loaders+=(Limine)
mapfile -t other_loaders < <(printf '%s\n' "${other_loaders[@]}" | sed '/^$/d' | sort -u)
# the login screen systemd starts (display-manager.service names it)
dm=$(readlink /etc/systemd/system/display-manager.service 2>/dev/null) || dm=
dm=${dm##*/}
dm=${dm%.service}

parts=()
login=none
if installed login; then
    login=sddm
elif [[ $dm == sddm ]]; then
    login=kept
    ask "Login screen: SDDM in Hyprdori's look and settings? (No: SDDM stays as it is)" y && login=sddm
elif [[ -n $dm ]]; then
    login=kept
    ask "Login screen: keep $dm? (No: Hyprdori's, SDDM in the theme's colors, takes its place)" y || login=sddm
elif ask "Login screen: Hyprdori's, SDDM in the theme's colors? (No: none; Hyprland is started from the console)" y; then
    login=sddm
fi
[[ $login == sddm ]] && parts+=(login)
splash=false
if installed splash; then
    splash=true
elif [[ ! -f /etc/mkinitcpio.conf ]]; then
    note "Boot splash: the initramfs isn't made by mkinitcpio here; no splash."
elif ask "Boot splash: Plymouth in the theme's colors, with the password field for encrypted drives?" y; then
    splash=true
fi
$splash && parts+=(splash)
menu=false
if installed menu; then
    menu=true
elif $own_limine; then
    note "Boot menu: Limine is set up here with its own menu; it's left as it is."
elif [[ $esp_at != /efi ]]; then
    note "Boot menu: Limine needs the ESP at /efi (${esp_at:-none found}); the boot loader stays as it is."
elif ((${#other_loaders[@]})); then
    ask "Boot menu: Limine in the theme's colors, first in the boot order? (No: ${other_loaders[*]} stays the boot menu; it stays installed either way)" n && menu=true
else
    ask "Boot menu: Limine in the theme's colors?" y && menu=true
fi
$menu && parts+=(menu)
# A btrfs root laid out as the install guide's (@ and @snapshots): snapshots, also in the boot
# menu when it's Limine
snapshots=false
if "$hw" btrfs &&
ask "Snapshots: before and after every update$($menu && echo ", bootable from the boot menu") (packages/snapshots.txt)?" y; then
    snapshots=true
    groups+=(snapshots)
    parts+=(snapshots)
fi
# With encrypted drives the disk password already guards the machine, so autologin is the default
encrypted=n
"$hw" encrypted && encrypted=y
autologin=--no-autologin
if [[ $login == sddm ]] && ask "Log in automatically, without the login screen (autologin)?" "$encrypted"; then
    autologin=--autologin
    note "Autologin: the disk password is the only one at boot; your account's password still unlocks the
lock screen and sudo. The keyring (saved browser and app passwords) isn't unlocked by a login: the
first app to use it asks for a keyring password, then every boot. Left empty, it never asks (the
encrypted disk still protects it)."
fi

echo
echo "Package lists: ${groups[*]}$($flatpak && echo ", flatpak"); boot parts: ${parts[*]:-none}$([[ $autologin == --autologin ]] && echo "; autologin")"
if $dry; then
    dry_report
    exit 0
fi
ask "Continue?" y || exit 0

# --- pacman.conf ----------------------------------------------------------------------------------
step "pacman.conf"
conf=/etc/pacman.conf
[[ -e $conf.bak ]] || { sudo cp "$conf" "$conf.bak" && record backup "$conf" "$conf.bak"; }
# multilib (Steam, lib32 drivers), colors, parallel downloads
sudo sed -i -e '/^#\[multilib\]$/,/^#Include/ s/^#//' \
    -e 's/^#Color$/Color/' -e 's/^#ParallelDownloads.*/ParallelDownloads = 5/' "$conf"
if [[ " ${groups[*]} " == *" laptop "* ]] && ! grep -q '^\[g14\]' "$conf"; then
    # Signing keys from asus-linux.org/guides/arch-guide
    for key in 8F654886F17D497FEFE3DB448B15A6B0E9A3FA35 F79100EF8C802DAB81C323BB8EEA5962FE510E19; do
        sudo pacman-key --recv-keys "$key" || sudo pacman-key --keyserver hkps://keyserver.ubuntu.com --recv-keys "$key"
        sudo pacman-key --lsign-key "$key"
    done
    printf '\n[g14]\nServer = https://arch.asus-linux.org\n' | sudo tee -a "$conf" >/dev/null
fi
echo "Done (the old one is $conf.bak)."

# --- Mirrors ----------------------------------------------------------------------------------------
step "Mirrors"
sudo pacman -Syu --needed --noconfirm reflector
if [[ ! -f /etc/pacman.d/mirrorlist.bak ]]; then
    sudo cp /etc/pacman.d/mirrorlist /etc/pacman.d/mirrorlist.bak
    record backup /etc/pacman.d/mirrorlist /etc/pacman.d/mirrorlist.bak
    sudo tee /etc/xdg/reflector/reflector.conf >/dev/null <<'EOF'
# reflector.timer runs this weekly (installed by install.sh)
--save /etc/pacman.d/mirrorlist
--protocol https
--latest 20
--sort rate
EOF
    echo "Ranking mirrors (about a minute)"
    sudo systemctl start reflector.service || note "reflector failed; keeping the old mirror list."
fi
sudo systemctl enable --now reflector.timer

# --- Links --------------------------------------------------------------------------------------------
step "Links"
sudo pacman -Syu --needed --noconfirm base-devel git stow
backup="$HOME/.hyprdori-backup/$(date +%F_%H-%M-%S)"
# Files in the way of the links move aside
moved=0
while IFS= read -r -d '' rel; do
    [[ -e $HOME/$rel || -L $HOME/$rel ]] || continue
    mkdir -p "$backup/$(dirname "$rel")"
    mv "$HOME/$rel" "$backup/$rel"
    moved=$((moved + 1))
done < <(in_the_way)
((moved)) && note "Moved $moved file(s) that were in the way to $backup" && record home-backup "$backup"
# Folders apps write into themselves made real first, so stow links the files in them rather
# than the whole folder into the repo: systemd keeps its timers' state next to the user units,
# hyprdori-webapp writes web apps' entries, herdr its sessions, plugins and logs, and
# ~/.local/lib is where pip and others put their own (Hyprdori's is lib/hyprdori, the commands'
# shared parts). On a fresh install they don't exist yet; existing ones are left as they are
mkdir -p "$HOME/.local/share/systemd/user" "$HOME/.local/share/applications" "$HOME/.config/herdr" "$HOME/.local/lib"
stow -d "$hyprdori" -t "$HOME" --restow "${packages[@]}"
echo "Linked: ${packages[*]}"
# A fresh install has nothing to migrate: hyprdori-update runs only migrations added later
"$hyprdori/local/.local/bin/hyprdori-migrate" --mark-done

# --- Packages -------------------------------------------------------------------------------------------
step "Packages"
if ! command -v paru >/dev/null; then
    echo "Building paru from the AUR"
    build=$(mktemp -d)
    git clone --depth 1 https://aur.archlinux.org/paru.git "$build/paru"
    # Its build tools and the package go in through sudo here, which still has the password:
    # makepkg's own installs (-s, -i) run sudo -k, which asks for it again
    mapfile -t deps < <(cd "$build/paru" && makepkg --printsrcinfo |
        sed -n -E 's/^\t(make|check)?depends = //p' | sed -E 's/[<>=].*//' | sort -u)
    ((${#deps[@]})) && sudo pacman -S --needed --noconfirm --asdeps "${deps[@]}"
    (cd "$build/paru" && makepkg --noconfirm)
    # paru's package, not the paru-debug one makepkg also builds
    sudo pacman -U --noconfirm "$build"/paru/paru-[0-9]*.pkg.tar.zst
    rm -rf "$build"
fi
mapfile -t wanted < <(wanted_packages)
# paru installs repo and AUR packages alike, and asks once. When that fails (an AUR package
# that doesn't build), the missing ones go again and the failures are listed: the install goes on.
# The repos' together: a dependency more than one package can fill (jack: pipewire-jack or jack2)
# is then filled by the one in the lists. One at a time with --noconfirm, pacman would take the
# first provider (jack2), which then blocks the listed one; when they must go one at a time, the
# ones that provide something go first, together. The AUR's after them, one at a time.
if ! paru -Syu --needed "${wanted[@]}"; then
    note "Not everything installed; trying the missing packages again"
    repo=() providers=() aur=() failed=()
    for pkg in "${wanted[@]}"; do
        pacman -Q "$pkg" &>/dev/null && continue
        if info=$(pacman -Si -- "$pkg" 2>/dev/null); then
            if grep -qE '^Provides +: [^N]' <<<"$info"; then providers+=("$pkg"); else repo+=("$pkg"); fi
        else
            aur+=("$pkg")
        fi
    done
    if ((${#providers[@]} + ${#repo[@]})) && ! sudo pacman -S --needed --noconfirm "${providers[@]}" "${repo[@]}"; then
        ((${#providers[@]})) && sudo pacman -S --needed --noconfirm "${providers[@]}" || true
        for pkg in "${providers[@]}" "${repo[@]}"; do
            pacman -Q "$pkg" &>/dev/null && continue
            sudo pacman -S --needed --noconfirm "$pkg" || failed+=("$pkg")
        done
    fi
    for pkg in "${aur[@]}"; do
        paru -S --needed --noconfirm "$pkg" || failed+=("$pkg")
    done
    if ((${#failed[@]})); then
        note "Not installed: ${failed[*]}. Try them later with paru -S."
    fi
fi
# Without a needed package the rest would set up what isn't there (a login screen's theme with
# no login screen): stop here, whatever kept it from installing
missing=()
while read -r pkg; do
    pacman -Q "$pkg" &>/dev/null || missing+=("$pkg")
done < <(needed_packages)
if ((${#missing[@]})); then
    printf '\n\e[1;31m%s\e[0m\n' "Needed and not installed: ${missing[*]}"
    echo "Stopped after the packages: no services, theme or boot screens were set up, and nothing
that was there before is changed. Install them (paru -S ${missing[*]}), then run
install.sh again: it skips what's done and goes on from here."
    exit 1
fi

# Flathub's apps: flatpak.txt if chosen, and the ones in the chosen lists (gaming.txt)
mapfile -t apps < <(wanted_flatpaks)
if ((${#apps[@]})); then
    step "Flatpak"
    sudo flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
    sudo flatpak install -y --noninteractive flathub "${apps[@]}"
fi

# --- Services, shell, theme -------------------------------------------------------------------------------
step "Services"
mapfile -t services < <(services_for)
# Hyprdori's login screen in place of another: that one is turned off first (systemd starts one)
if [[ $login == sddm && -n $dm && $dm != sddm ]]; then
    sudo systemctl disable "$dm.service" &>/dev/null && record disable "$dm.service" && echo "Turned off $dm (SDDM takes its place)"
fi
vm=false
[[ " ${groups[*]} " == *" vm "* ]] && vm=true
for unit in "${services[@]}"; do
    if systemctl is-enabled -q "$unit" 2>/dev/null; then
        echo "Enabled already: $unit"
    elif sudo systemctl enable "$unit" &>/dev/null; then
        echo "Enabled $unit"
        record enable "$unit"
    else
        note "Couldn't enable $unit"
    fi
done
# Per user: the weekly update check (Saturdays; a notification when updates wait), linked from bin
systemctl --user daemon-reload
if systemctl --user enable --now hyprdori-update-check.timer &>/dev/null; then
    echo "Enabled the weekly update check"
else
    note "Couldn't enable the weekly update check (systemctl --user enable --now hyprdori-update-check.timer)"
fi
# The lock screen gets up to 15 s, not logind's 5, to come up before a suspend
# (hyprdori-sleep-lock). logind reads it on reload.
[[ -e /etc/systemd/logind.conf.d/20-inhibit-delay.conf ]] || record file /etc/systemd/logind.conf.d/20-inhibit-delay.conf
sudo install -Dm644 /dev/stdin /etc/systemd/logind.conf.d/20-inhibit-delay.conf <<'EOF'
[Login]
InhibitDelayMaxSec=15
EOF
sudo systemctl reload systemd-logind || note "Couldn't reload logind; the longer lock delay applies after a reboot"
if $vm; then
    # VMs without a password prompt, and libvirt's NAT network up on every boot
    sudo usermod -aG libvirt "$USER"
    sudo systemctl start libvirtd
    sudo virsh net-autostart default >/dev/null && echo "libvirt's default network starts on boot" \
        || note "Couldn't set libvirt's default network to start on boot"
fi

step "Shell"
if [[ $(getent passwd "$USER" | cut -d: -f7) != */zsh ]]; then
    record shell "$(getent passwd "$USER" | cut -d: -f7)"
    sudo chsh -s /usr/bin/zsh "$USER"
else
    echo "Already zsh."
fi
# zsh's plugins (vi mode, highlighting, suggestions, completions, history search)
"$HOME/.local/bin/hyprdori-zsh-plugins"
# yazi's plugins from its package list (yazi/.config/yazi/package.toml: full-border, at the
# version it names)
command -v ya >/dev/null && { ya pkg install >/dev/null || note "Couldn't install yazi's plugins (ya pkg install)"; }
# herdr's Ctrl+H/J/K/L across its panes and Neovim's splits (herdr/.config/herdr/config.toml)
if command -v herdr >/dev/null && ! herdr plugin list 2>/dev/null | grep -q vim-herdr-navigation; then
    herdr plugin install --yes paulbkim-dev/vim-herdr-navigation >/dev/null || note "Couldn't install herdr's navigation plugin"
fi
# Neovim's plugins at lazy-lock.json's versions (the lock file stays as it is), so its first
# start has nothing to download; without them now, Neovim installs them when it first starts
if command -v nvim >/dev/null; then
    echo "Installing Neovim's plugins (lazy-lock.json's versions)"
    nvim --headless "+Lazy! restore" +qa >/dev/null 2>&1 || note "Couldn't install Neovim's plugins now; Neovim installs them when it first starts"
fi

step "Theme"
# The login screen first (when chosen): hyprdori-theme-set writes its colors to the folder this makes
[[ $login == sddm ]] && sudo "$hyprdori/sddm/install.sh" "$autologin" >/dev/null
# tmux's theme plugin (.tmux.conf would clone it on first start), so hyprdori-theme-set can write
# the theme's colors into it now
tmux_theme="$HOME/.tmux/plugins/catppuccin/tmux"
[[ -d $tmux_theme ]] || git clone -q -b v2.3.2 https://github.com/catppuccin/tmux.git "$tmux_theme"
# What opens what, on a machine that has no such choices yet: the web in Chromium (the default
# browser; hyprdori-browser set changes it), images in swayimg, PDFs in zathura, video and
# sound in VLC. The file is the machine's own afterwards: an existing one is left as it is
mimeapps=${XDG_CONFIG_HOME:-$HOME/.config}/mimeapps.list
[[ -e $mimeapps ]] || { install -Dm644 "$hyprdori/packages/mimeapps.list" "$mimeapps" && record file "$mimeapps"; }
# The browsers' color policy helper, so the theme below colors the Chromium-based browsers too
sudo "$HOME/.local/bin/hyprdori-browser-theme-setup" >/dev/null
# and the browsers' font, as answered above (no sudo: a per-user setting)
"$HOME/.local/bin/hyprdori-browser-theme-setup" --follow-font "$browser_font" >/dev/null
"$HOME/.local/bin/hyprdori-theme-set"
# Backgrounds: ~/.local/share/hyprdori/backgrounds/default (wallpapers) and /live, and
# ~/.config/hyprdori/backgrounds.json for more folders. The desktop, lock screen and login
# screen get the theme's background, which hyprdori-theme-set just drew (the logo in magenta on
# the dark background), unless a wallpaper is chosen already. Both follow
# the theme from then on.
wall=$(jq -r '.background // empty' "$HOME/.config/theme/current/quickshell.json" 2>/dev/null) || wall=
"$HOME/.local/bin/hyprdori-wallpaper" default ${wall:+"$wall"}

# The initramfs is built again at the end when a step below changes what goes into it
rebuild=false
# --- Snapshots: snapper on @snapshots, limine-snapper-sync, read-only snapshots with an overlay -------------
if $snapshots && command -v snapper >/dev/null; then
    step "Snapshots"
    # snapper's config for /, its snapshots in @snapshots (mounted at /.snapshots by fstab) rather
    # than the subvolume snapper makes itself
    if ! sudo snapper list-configs 2>/dev/null | grep -q '^root '; then
        mountpoint -q /.snapshots && sudo umount /.snapshots
        sudo rmdir /.snapshots 2>/dev/null || true
        sudo snapper -c root create-config /
        # fstab mounts @snapshots there (the install guide): snapper's own subvolume makes way
        if findmnt --fstab /.snapshots >/dev/null; then
            sudo btrfs subvolume delete /.snapshots >/dev/null
            sudo mkdir /.snapshots
            sudo mount -a
            echo "snapper's root config, snapshots in @snapshots"
        else
            echo "snapper's root config, snapshots in its own /.snapshots subvolume"
        fi
    fi
    sudo chmod 750 /.snapshots
    # Only the update snapshots: one before every hyprdori-update, the newest 5 kept, cleaned up
    # at once (no minimum age); no hourly timeline, so the boot menu's Snapshots stay short. Only
    # /: /home holds the user's work, never rolled back
    sudo snapper -c root set-config TIMELINE_CREATE=no NUMBER_LIMIT=5 NUMBER_LIMIT_IMPORTANT=5 NUMBER_MIN_AGE=0
    sudo systemctl enable --now snapper-cleanup.timer
    # The boot menu's snapshots: their entries in /efi/limine.conf (limine/install.sh adds the
    # place), booted read-only with a throwaway layer on top (systemd.volatile=overlay: the
    # initramfs gets systemd's volatile-root service, which the systemd hook leaves out, and the
    # overlay module), restored with limine-snapper-restore
    if $menu && command -v limine-snapper-sync >/dev/null; then
        record file /etc/default/limine
        record file /etc/mkinitcpio.conf.d/snapshots.conf
        sudo tee /etc/default/limine >/dev/null <<CONF
# limine-snapper-sync, written by Hyprdori's install.sh
ESP_PATH="/efi"
TARGET_OS_NAME="Arch Linux"
SNAPPER_CONFIG_NAME="root"
LIMIT_USAGE_PERCENT=85
MAX_SNAPSHOT_ENTRIES=auto
SNAPSHOT_KERNEL_PARAMETERS+=systemd.volatile=overlay
SNAPSHOT_WRITABLE=no
RESTORE_METHOD=replace
SNAPSHOT_FORMAT_CHOICE=2
TERMINAL=kitty
TERMINAL_ARG="-e"
CONF
        sudo install -d /etc/mkinitcpio.conf.d
        sudo tee /etc/mkinitcpio.conf.d/snapshots.conf >/dev/null <<'CONF'
# Booting a read-only snapshot with a throwaway layer (systemd.volatile=overlay, install.sh)
MODULES+=(overlay)
BINARIES+=(/usr/lib/systemd/systemd-volatile-root)
FILES+=(/usr/lib/systemd/system/systemd-volatile-root.service)
CONF
        sudo systemctl enable limine-snapper-sync.service
        rebuild=true
        echo "Snapshots in the boot menu (/etc/default/limine, /etc/mkinitcpio.conf.d/snapshots.conf)"
    elif $menu; then
        note "limine-snapper-sync isn't installed: snapshots are taken, but not in the boot menu."
    fi
    # Copy-on-write off where VM disks and Docker's data go (files made after this)
    sudo install -d /var/lib/libvirt/images /var/lib/docker
    sudo chattr +C /var/lib/libvirt/images /var/lib/docker
fi

# --- Boot: initramfs, splash, menu and its kernel options ------------------------------------------------
step "Boot"
mkinit=/etc/mkinitcpio.conf
# GPU drivers in the initramfs, named rather than the kms hook's (every built-in driver, but not
# NVIDIA's DKMS modules): the boot screen's GPU for the splash, and NVIDIA's on any machine with
# an NVIDIA card, also a hybrid laptop. Loaded later, it can appear after the login screen's
# Hyprland has started, which doesn't survive a new GPU. NVIDIA's firmware makes the images
# about 150 MB each.
if [[ -f $mkinit ]] && { $splash || [[ $login == sddm ]]; }; then
    [[ -e $mkinit.bak ]] || { sudo cp "$mkinit" "$mkinit.bak" && record backup "$mkinit" "$mkinit.bak"; }
    if grep -q '^MODULES=()' "$mkinit"; then
        case $boot_gpu in
            0x8086) modules=${boot_driver:-i915}; [[ $modules == xe ]] || modules=i915 ;;
            0x1002) modules=amdgpu ;;
            *) modules= ;;
        esac
        [[ -n $modules ]] && sudo sed -i "s/^MODULES=()/MODULES=($modules)/" "$mkinit" && echo "MODULES=($modules)" && rebuild=true
    fi
    if has_gpu 0x10de && [[ ! -f /etc/mkinitcpio.conf.d/nvidia.conf ]]; then
        sudo install -d /etc/mkinitcpio.conf.d
        echo 'MODULES+=(nvidia nvidia_modeset nvidia_uvm nvidia_drm)' | sudo tee /etc/mkinitcpio.conf.d/nvidia.conf >/dev/null
        record file /etc/mkinitcpio.conf.d/nvidia.conf
        echo "NVIDIA in the initramfs (/etc/mkinitcpio.conf.d/nvidia.conf)"
        rebuild=true
    fi
    if grep -qE '^HOOKS=.*\bkms\b' "$mkinit" && { grep -qE '^MODULES=\(.+\)' "$mkinit" || [[ -f /etc/mkinitcpio.conf.d/nvidia.conf ]]; }; then
        sudo sed -i -E '/^HOOKS=/{s/ kms\b//}' "$mkinit"
        rebuild=true
    fi
fi
# The splash's hook, right after the one that starts udev: systemd's, or busybox's udev (the
# disk password then goes through Plymouth with either encrypt hook)
if $splash && ! grep -qE '^HOOKS=.*\bplymouth\b' "$mkinit"; then
    if grep -qE '^HOOKS=\(.*\bsystemd\b' "$mkinit"; then
        sudo sed -i -E '/^HOOKS=/s/\bsystemd\b/systemd plymouth/' "$mkinit"
    elif grep -qE '^HOOKS=\(.*\budev\b' "$mkinit"; then
        sudo sed -i -E '/^HOOKS=/s/\budev\b/udev plymouth/' "$mkinit"
    else
        note "The initramfs has neither the systemd nor the udev hook; no splash."
        splash=false
    fi
    $splash && record hook plymouth
fi

# Kernel options: a quiet boot and shutdown (no kernel or systemd status text, no console
# cursor); with the splash, the splash itself, the unlock limits that luks-poweroff relies on
# (90 seconds or three tries, then power off: systemd's unlock), and two against boot hangs
# under Plymouth: since kernel 7.1 the initramfs is unpacked while /init already runs, which can
# make Plymouth quit (the disk password asked in plain text); since systemd 257 it asks the
# console its size and can wait for a reply that never comes under Plymouth (a black screen at
# "Starting Switch Root" until a key is pressed)
running=$(sed -E 's/(^| )(BOOT_IMAGE|initrd)=[^ ]*//g; s/^ +//' /proc/cmdline)
extra=(quiet loglevel=3 systemd.show_status=false vt.global_cursor_default=0)
if $splash; then
    extra+=(splash initramfs_async=0 systemd.tty.term.console=dumb)
    if [[ $running == *rd.luks.name=* ]] && grep -qE '^HOOKS=.*\bsd-encrypt\b' "$mkinit"; then
        extra+=(rd.luks.options=timeout=90s,tries=3 systemd.default_device_timeout_sec=infinity)
    fi
fi
has_option() { [[ " $1 " == *" ${2%%=*}="* || " $1 " == *" $2 "* ]]; }

if $menu; then
    # Kernels and images on the ESP, where Limine can read them (it reads only FAT)
    sudo install -d /efi/arch
    for preset in /etc/mkinitcpio.d/*.preset; do
        kernel=$(basename "$preset" .preset)
        grep -q '^ALL_kver="/efi/arch/' "$preset" && continue
        [[ -e $preset.bak ]] || { sudo cp "$preset" "$preset.bak" && record backup "$preset" "$preset.bak"; }
        sudo tee "$preset" >/dev/null <<EOF
# mkinitcpio preset for $kernel; the kernel and image go to the ESP (install.sh)
ALL_kver="/efi/arch/vmlinuz-$kernel"
PRESETS=('default')
default_image="/efi/arch/initramfs-$kernel.img"
EOF
        echo "$kernel: kernel and image now go to /efi/arch"
        rebuild=true
    done
    # Limine's kernel options: the running system's, plus the ones above
    if [[ ! -s /etc/kernel/cmdline ]]; then
        echo "$running" | sudo tee /etc/kernel/cmdline >/dev/null
        record file /etc/kernel/cmdline
    fi
    cmdline=$(cat /etc/kernel/cmdline)
    for option in "${extra[@]}"; do
        has_option "$cmdline" "$option" && continue
        cmdline+=" $option"
        record kernel-option "$option"
    done
    echo "$cmdline" | sudo tee /etc/kernel/cmdline >/dev/null
    echo "Kernel options: $cmdline"
    # Other systems' boot menu entries (Windows, another distro, the UEFI shell) go in this
    # file, kept when the menu is written again; made once, with only comments and an example
    if [[ ! -e /etc/hyprdori/limine-entries.conf ]]; then
        sudo install -D -m 0644 "$hyprdori/limine/limine-entries.conf" /etc/hyprdori/limine-entries.conf
    fi
fi

# The splash builds the initramfs (and with the menu, the kernels in /efi/arch); without it,
# changes above are built here. Limine then finds the kernels in /efi/arch
if $splash; then
    sudo "$hyprdori/plymouth/install.sh" --theme
elif $rebuild; then
    sudo mkinitcpio -P
fi
$menu && sudo "$hyprdori/limine/install.sh" --theme
# Another boot loader keeps its own kernel options: the splash's, printed to add there
add=()
if $splash && ! $menu; then
    for option in "${extra[@]}"; do has_option "$running" "$option" || add+=("$option"); done
fi
if ! $splash && ! $menu && ! $rebuild; then
    echo "No boot splash or menu chosen: the boot is left as it is."
fi

step "Done"
# Everything this run installed, explicitly (dependencies go with them on removal)
while read -r pkg; do record package "$pkg"; done < <(comm -13 "$before" <(pacman -Qqe | sort))
if command -v flatpak >/dev/null; then
    while read -r app; do record flatpak "$app"; done < <(comm -13 "$flatpaks_before" <(flatpak list --app --columns=application 2>/dev/null | sort))
fi
if ((${#add[@]})); then
    note "The boot splash needs these kernel options, added to the boot loader's own (${other_loaders[*]:-the boot loader}):
  ${add[*]}
GRUB: GRUB_CMDLINE_LINUX_DEFAULT in /etc/default/grub, then sudo grub-mkconfig -o /boot/grub/grub.cfg.
systemd-boot: the options line of each entry in /boot/loader/entries/ (or /etc/kernel/cmdline for
unified kernel images, then sudo mkinitcpio -P)."
fi
[[ $login == none ]] && note "No login screen: log in on the console and run Hyprland to start the desktop."
cat <<MSG
Reboot.$([[ $login == sddm ]] && echo " The login screen gets your monitor layout by itself, at every login and monitor change.")
$(command -v spotify-launcher >/dev/null && printf '\n%s\n' "Spotify follows the theme once you've opened it and logged in: at the next login after that
it's styled by itself (hyprdori-spicetify; or run that with Spotify closed).")

What this changed outside the home folder, and what it installed: $ledger (uninstall.sh undoes it).
MSG
