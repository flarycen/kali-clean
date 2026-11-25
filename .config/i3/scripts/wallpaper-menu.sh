#!/usr/bin/env bash
# Mod+Shift+B: pick a wallpaper from ~/.wallpaper (your own images appear too).
set -Eeuo pipefail

wall_dir="$HOME/.wallpaper"
setter="$HOME/.config/i3/scripts/set-wallpaper.sh"
[[ -d "$wall_dir" ]] || exit 0
command -v rofi >/dev/null 2>&1 || exit 0

label_for() {
    case "$1" in
        contour.png) printf 'Contour   dark topographic lines (default)' ;;
        black.png)   printf 'Black     solid near-black' ;;
        dots.png)    printf 'Dots      faint dot grid' ;;
        grid.png)    printf 'Grid      fine line grid' ;;
        grain.png)   printf 'Grain     subtle film grain' ;;
        *)           printf '%s' "$1" ;;
    esac
}

current="$(basename -- "$(readlink -f -- "$wall_dir/current" 2>/dev/null || true)")"

mapfile -t files < <(find "$wall_dir" -maxdepth 1 -type f \
    \( -iname '*.png' -o -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.webp' \) \
    -printf '%f\n' | sort)
((${#files[@]})) || exit 0

menu=''
for file in "${files[@]}"; do
    mark=' '
    [[ "$file" == "$current" ]] && mark='*'
    menu+="$mark $file  ::  $(label_for "$file")"$'\n'
done

selection="$(printf '%s' "$menu" | rofi -dmenu -i -p 'wallpaper' -no-custom || true)"
[[ -n "$selection" ]] || exit 0

file="${selection:2}"
file="${file%%  ::  *}"
[[ -n "$file" && "$file" != */* && -f "$wall_dir/$file" ]] || exit 1

ln -sfn -- "$file" "$wall_dir/current"
/usr/bin/env bash "$setter"
command -v notify-send >/dev/null 2>&1 && notify-send -a kali-clean 'Wallpaper' "$(label_for "$file")" >/dev/null 2>&1 || true
