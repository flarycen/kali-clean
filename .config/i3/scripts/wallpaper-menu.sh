#!/usr/bin/env bash
set -Eeuo pipefail

wall_dir="$HOME/.wallpaper"
setter="$HOME/.config/i3/scripts/set-wallpaper.sh"
[[ -d "$wall_dir" ]] || exit 0

mapfile -t files < <(find "$wall_dir" -maxdepth 1 -type f \( -iname '*.png' -o -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.webp' \) -printf '%f\n' | sort)
((${#files[@]})) || exit 0

label_for() {
    case "$1" in
        default.png) printf 'Contour — default' ;;
        relief.png)  printf 'Relief — black topography' ;;
        spectre.png) printf 'Spectre — monochrome figure' ;;
        amber.png)   printf 'Amber — warm abstract' ;;
        *)           printf '%s' "$1" ;;
    esac
}

menu=''
for file in "${files[@]}"; do
    menu+="$file  $(label_for "$file")"$'\n'
done

selection="$(printf '%s' "$menu" | rofi -dmenu -i -p 'Wallpaper' -no-custom || true)"
[[ -n "$selection" ]] || exit 0
file="${selection%%  *}"
[[ -f "$wall_dir/$file" ]] || exit 1

ln -sfn "$file" "$wall_dir/current"
/usr/bin/env bash "$setter"
command -v notify-send >/dev/null 2>&1 && notify-send -a kali-clean 'Wallpaper' "$(label_for "$file")" >/dev/null 2>&1 || true
