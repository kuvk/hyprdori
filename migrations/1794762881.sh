#!/usr/bin/env bash
# hyprdori-gamemode became hyprdori-mode: the old command's link, left pointing at nothing, goes
old=$HOME/.local/bin/hyprdori-gamemode
if [[ -L $old && ! -e $old ]]; then
    rm -f "$old"
    echo "Removed the old link ~/.local/bin/hyprdori-gamemode"
fi
exit 0
