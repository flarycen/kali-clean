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
#
# Each copy adds one line (time, size, tool; never the text) to
# ~/.local/state/kali-clean/clip.log; clipcheck.py shows the latest ones.
data=$(cat; printf x)       # the x keeps trailing newlines
data=${data%x}

put() {     # put SELECTION: prints the tool that worked, or FAILED
    if command -v xsel >/dev/null 2>&1 &&
        printf '%s' "$data" | xsel --"$1" --input --logfile /dev/null >/dev/null 2>&1; then
        echo xsel; return 0
    fi
    if command -v xclip >/dev/null 2>&1 &&
        printf '%s' "$data" | xclip -selection "$1" -in >/dev/null 2>&1; then
        echo xclip; return 0
    fi
    echo FAILED; return 1
}

clip=$(put clipboard)
prim=$(put primary)

case ${XDG_STATE_HOME:-} in
    /*) log_dir=$XDG_STATE_HOME/kali-clean ;;
    *)  log_dir=$HOME/.local/state/kali-clean ;;
esac
if mkdir -p "$log_dir" 2>/dev/null; then
    log=$log_dir/clip.log
    if [ -f "$log" ] && [ "$(wc -c < "$log")" -gt 32768 ]; then
        tail -n 100 "$log" > "$log.tmp" && mv -f "$log.tmp" "$log"
    fi
    printf '%s %s bytes clipboard=%s primary=%s display=%s\n' "$(date '+%F %T')" \
        "${#data}" "$clip" "$prim" "${DISPLAY:-unset}" >> "$log" 2>/dev/null
fi
[ "$clip" != FAILED ] || [ "$prim" != FAILED ]
