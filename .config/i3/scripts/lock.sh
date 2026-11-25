#!/usr/bin/env bash
# Mod+Shift+X: lock the screen with a plain near-black i3lock.
# -c/-e/-f work with both i3lock and Kali's i3lock-color.
set -u
if command -v i3lock >/dev/null 2>&1; then
    exec i3lock -c 060606 -e -f
fi
command -v notify-send >/dev/null 2>&1 && notify-send -a kali-clean 'Lock' 'i3lock is not installed'
exit 1
