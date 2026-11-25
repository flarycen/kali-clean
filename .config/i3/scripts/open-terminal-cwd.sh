#!/usr/bin/env bash
# Mod+Enter: open Alacritty in the focused terminal's current directory.
# The zsh prompt records each terminal window's directory in a small cache,
# which works even when the shell runs inside tmux.
set -u

cwd="$HOME"
window_id=''
pid=''
cache_dir="${XDG_CACHE_HOME:-$HOME/.cache}/kali-clean/cwd"

if command -v i3-msg >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
    focused="$(i3-msg -t get_tree 2>/dev/null \
        | jq -r '.. | objects | select(.focused? == true) | [(.window // "" | tostring), (.pid // "" | tostring)] | @tsv' 2>/dev/null \
        | head -n1)"
    if [[ -n "$focused" ]]; then
        IFS=$'\t' read -r window_id pid <<< "$focused"
    fi
fi

if [[ "$window_id" =~ ^[0-9]+$ && -L "$cache_dir/$window_id" ]]; then
    candidate="$(readlink -e -- "$cache_dir/$window_id" 2>/dev/null || true)"
    [[ -n "$candidate" && -d "$candidate" ]] && cwd="$candidate"
fi

if [[ "$cwd" == "$HOME" && "$pid" =~ ^[0-9]+$ && -d "/proc/$pid" ]]; then
    candidate="$(readlink -e -- "/proc/$pid/cwd" 2>/dev/null || true)"
    [[ -n "$candidate" && -d "$candidate" ]] && cwd="$candidate"
fi

if command -v alacritty >/dev/null 2>&1; then
    started=$SECONDS
    alacritty --working-directory "$cwd"
    status=$?
    # Only fall back when Alacritty failed to start (e.g. no usable OpenGL),
    # never after the user simply closed a working terminal.
    if (( status == 0 || SECONDS - started > 3 )); then
        exit 0
    fi
fi

cd -- "$cwd" 2>/dev/null || cd -- "$HOME" || true
exec x-terminal-emulator
