#!/usr/bin/env bash
# Installs Hyprdori in one command: clones the repo to ~/.src/hyprdori and runs its install.sh,
# with the terminal for its questions. Every decision is install.sh's; this only gets it there.
#
#   curl -fsSL https://raw.githubusercontent.com/kuvk/hyprdori/main/boot.sh | bash
#   curl -fsSL https://raw.githubusercontent.com/kuvk/hyprdori/main/boot.sh | bash -s -- --dry-run
#
# What follows bash -s -- goes to install.sh (--dry-run: what it would do, nothing changed).
# HYPRDORI_REF picks the branch or tag to clone (main by default). An existing clone is used as it
# is, not updated: git pull in it first for a newer one.

# -h, --help: the comment above, then nothing else runs (read from the file, not through a pipe)
case ${1:-} in -h | --help) awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; exit 0 ;; esac
set -euo pipefail

main() {
    local repo=https://github.com/kuvk/hyprdori dir=$HOME/.src/hyprdori ref=${HYPRDORI_REF:-main}
    die() { printf 'hyprdori: %s\n' "$1" >&2; exit 1; }
    ((EUID != 0)) || die "run this as yourself, not root: the install asks for sudo when it needs it"
    [[ -f /etc/arch-release ]] || die "Hyprdori is for Arch Linux"
    command -v sudo >/dev/null || die "sudo isn't installed: pacman -S sudo (as root), and a user who may use it"
    # the install's questions read the terminal (bash reads this script from the pipe); a dry run
    # without one takes their defaults
    local tty=true
    { : </dev/tty; } 2>/dev/null || tty=false
    $tty || [[ " $* " == *" --dry-run "* ]] || die "no terminal for the install's questions: run this in a terminal"

    if ! command -v git >/dev/null; then
        printf '==> Installing git (asks for the sudo password)\n'
        sudo pacman -S --needed --noconfirm git
    fi
    if [[ -d $dir/.git ]]; then
        printf '==> Using the clone in %s\n' "$dir"
    elif [[ -e $dir ]]; then
        die "$dir is there and isn't a clone of Hyprdori: move it, then run this again"
    else
        printf '==> Cloning Hyprdori into %s\n' "$dir"
        mkdir -p "${dir%/*}"
        git clone --branch "$ref" "$repo" "$dir"
    fi
    if $tty; then
        exec "$dir/install.sh" "$@" </dev/tty
    fi
    exec "$dir/install.sh" "$@" </dev/null
}

# All of it in a function, so nothing runs until bash has read the whole script through the pipe
main "$@"
