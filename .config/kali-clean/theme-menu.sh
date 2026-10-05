#!/usr/bin/env bash
set -Eeuo pipefail

base="$HOME/.config/kali-clean"
current_theme="$(cat "$base/theme" 2>/dev/null || printf obsidian)"
rofi_theme="$base/current/rofi.rasi"
[[ -f "$rofi_theme" ]] || rofi_theme="$base/themes/obsidian/rofi.rasi"

mark() {
    local name=$1
    [[ "$current_theme" == "$name" ]] && printf '●' || printf '○'
}

menu="$(mark obsidian)  Obsidian   — perfect minimalism, monochrome, quiet\n$(mark neon)  Neon       — cyan/violet accents, richer launcher + tmux\n"
selection="$(printf '%b' "$menu" | rofi -dmenu -i -p 'Theme' -no-custom -theme "$rofi_theme" || true)"
[[ -n "$selection" ]] || exit 0

case "$selection" in
    *Obsidian*) exec /usr/bin/env bash "$base/apply-theme.sh" obsidian ;;
    *Neon*)     exec /usr/bin/env bash "$base/apply-theme.sh" neon ;;
esac
