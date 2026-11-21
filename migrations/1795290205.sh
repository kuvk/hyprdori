#!/usr/bin/env bash
# install.sh no longer reads ~/.config/hyprdori/user_pkg.txt: extra packages go in
# packages/apps.txt. The file goes where it holds only its notes; with packages in it, it stays
# and says where they belong now.
file=${XDG_CONFIG_HOME:-$HOME/.config}/hyprdori/user_pkg.txt
[[ -e $file ]] || exit 0
mapfile -t pkgs < <(sed 's/#.*//; s/[[:space:]]//g; /^$/d' "$file")
if ((${#pkgs[@]} == 0)); then
    rm -f "$file"
    echo "Removed ~/.config/hyprdori/user_pkg.txt (only notes; install.sh no longer reads it)"
else
    echo "$file is no longer read: move ${pkgs[*]} to packages/apps.txt, then delete it"
fi
