#!/usr/bin/env bash
# Best-effort current-directory terminal launcher with a reliable fallback.
set -u

cwd="$HOME"
pid=''
window_id=''
cache_dir="${XDG_CACHE_HOME:-$HOME/.cache}/kali-clean/cwd"

if command -v i3-msg >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
    focused="$(i3-msg -t get_tree 2>/dev/null | jq -r '.. | objects | select(.focused? == true) | [(.window // ""), (.pid // "")] | @tsv' | head -n1)"
    if [[ -n "$focused" ]]; then
        IFS=$'\t' read -r window_id pid <<< "$focused"
    fi
fi

if [[ "$window_id" =~ ^[0-9]+$ && -L "$cache_dir/$window_id" ]]; then
    candidate="$(readlink -e "$cache_dir/$window_id" 2>/dev/null || true)"
    [[ -n "$candidate" && -d "$candidate" ]] && cwd="$candidate"
fi

if [[ "$cwd" == "$HOME" && "$pid" =~ ^[0-9]+$ && -d "/proc/$pid" ]]; then
    candidate="$(readlink -e "/proc/$pid/cwd" 2>/dev/null || true)"
    [[ -n "$candidate" && -d "$candidate" ]] && cwd="$candidate"
fi

if command -v alacritty >/dev/null 2>&1; then
    alacritty --working-directory "$cwd" && exit 0
fi

# If Alacritty fails because of a local GPU/config issue, still give the user a terminal.
if command -v kitty >/dev/null 2>&1; then
    exec kitty --directory "$cwd"
fi
exec x-terminal-emulator
