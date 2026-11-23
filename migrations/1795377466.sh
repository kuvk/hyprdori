#!/usr/bin/env bash
# Folders open in yazi, and zathura's config comes from the repo. Earlier installs had no folder
# handler (kitty's open handler took them), and zathura's zathurarc was a file of its own. A
# yazi.desktop and a zathurarc in the way of the links move to ~/.hyprdori-backup, the two folders
# are stowed again, and folders are set to open in yazi unless something else was chosen.
hyprdori=${HYPRDORI_PATH:?}
backup="$HOME/.hyprdori-backup/$(date +%F_%H-%M-%S)"

for rel in .local/share/applications/yazi.desktop .config/zathura/zathurarc; do
    file=$HOME/$rel
    # nothing there, a link, or the repo's own file reached through a linked folder
    # (~/.config/zathura linked whole when it didn't exist yet): left alone
    [[ -L $file || ! -e $file || $(realpath "$file") == "$hyprdori"/* ]] && continue
    mkdir -p "$backup/$(dirname "$rel")"
    mv "$file" "$backup/$rel"
    echo "Moved ~/$rel to $backup"
done

stow -d "$hyprdori" -t "$HOME" --restow local zathura

current=$(xdg-mime query default inode/directory 2>/dev/null)
# none, kitty's open handler, or yazi only through a cache: yazi, written to mimeapps.list
if [[ -z $current || $current == kitty-open.desktop || $current == yazi.desktop ]]; then
    xdg-mime default yazi.desktop inode/directory
    echo "Folders open in yazi"
fi
