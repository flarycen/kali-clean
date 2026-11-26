#!/bin/sh
# kali-clean: copy stdin to the X CLIPBOARD and PRIMARY selections.
# Used as tmux's copy-command (mouse selections and copy-mode).
#
# Both selections, and xsel before xclip, so copies reach the VMware host. On
# a guest->host copy, VMware Tools asks CLIPBOARD and PRIMARY for their
# TIMESTAMP and sends the newer one, or PRIMARY on a tie (open-vm-tools,
# CopyPasteUIX11::LocalPrimTimestampCB). xclip answers TIMESTAMP with the text
# itself, which VMware rejects, and PRIMARY is usually still held by VMware
# Tools with the host's previous clipboard. A copy made with xclip to CLIPBOARD
# alone therefore sent the host its old clipboard (often an empty line).
# xsel answers TIMESTAMP correctly; with xclip only, owning PRIMARY too still
# makes VMware pick our text.
data=$(cat; printf x)       # the x keeps trailing newlines
data=${data%x}
status=1
for sel in clipboard primary; do
    if command -v xsel >/dev/null 2>&1; then
        printf '%s' "$data" | xsel --"$sel" --input >/dev/null 2>&1 && status=0
    elif command -v xclip >/dev/null 2>&1; then
        printf '%s' "$data" | xclip -selection "$sel" -in >/dev/null 2>&1 && status=0
    fi
done
exit "$status"
