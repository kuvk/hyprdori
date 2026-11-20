#!/usr/bin/env bash
# Two kernel options against boot hangs with Plymouth (initramfs_async=0: the initramfs unpacked
# before /init runs; systemd.tty.term.console=dumb: no console size query that can stall at
# "Starting Switch Root"): the boot menu is written again with them, with the options it was
# installed with.
conf=/efi/limine.conf
[[ -s /etc/kernel/cmdline ]] && grep -q 'Written by limine/install.sh' "$conf" 2>/dev/null || exit 0
sudo -v || exit 1
cmdline=$(</etc/kernel/cmdline)
for option in initramfs_async=0 systemd.tty.term.console=dumb; do
    [[ " $cmdline " == *" ${option%%=*}="* ]] || cmdline+=" $option"
done
echo "$cmdline" | sudo tee /etc/kernel/cmdline >/dev/null
read -ra options <<<"$(sed -n 's/^# Options: //p' "$conf")"
sudo "$HYPRDORI_PATH/limine/install.sh" "${options[@]}" >/dev/null
echo "Kernel options added and the boot menu written again"
