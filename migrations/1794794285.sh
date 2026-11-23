#!/usr/bin/env bash
# The browsers' color helper again, where it's set up: it now also writes Chrome's policy folder
# (the folders come from the browsers' table), so a Chromium-based browser installed later is
# colored too.
[[ -e /usr/local/bin/browser-theme-policy ]] || exit 0
sudo -v || exit 1
sudo "$HOME/.local/bin/hyprdori-browser-theme-setup" >/dev/null
