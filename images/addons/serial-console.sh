#!/usr/bin/env bash
# Build the serial console UKI addon:
#
#   images/addons/serial-console.sh <out.addon.efi> [console-arguments]
#
# The image's UKI has no console= argument, so the kernel uses the default
# console (tty0) and the getty generator starts no serial getty: on hardware
# without a UART, console=ttyS0 makes it start serial-getty@ttyS0, which
# fails and restarts every 10 seconds (the 8250 driver always has a ttyS0
# node, so there is nothing to check for). On a machine that has a serial
# console, copy the addon to \loader\addons\ on the ESP (systemd-stub appends
# its .cmdline to the UKI's, no rebuild of the image). Secure Boot must be off
# (unsigned addon, like the image's UKI). The arguments default to
# "console=tty0 console=ttyS0,115200n8": the last console= is /dev/console.
set -euo pipefail

out=${1:?usage: serial-console.sh <out.addon.efi> [console-arguments]}
cmdline=${2:-console=tty0 console=ttyS0,115200n8}

mkdir -p "$(dirname "$out")"
ukify build --stub /usr/lib/systemd/boot/efi/addonx64.efi.stub \
  --cmdline "$cmdline" --output "$out"
