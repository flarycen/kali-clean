#!/usr/bin/env bash
set -Eeuo pipefail

wall_dir="$HOME/.wallpaper"
setter="$HOME/.config/i3/scripts/set-wallpaper.sh"
fetcher="$HOME/.config/i3/scripts/wallpaper-fetch.sh"
rofi_theme="$HOME/.config/kali-clean/current/rofi.rasi"
[[ -f "$rofi_theme" ]] || rofi_theme="$HOME/.config/kali-clean/themes/obsidian/rofi.rasi"
[[ -d "$wall_dir" ]] || exit 0

label_for() {
    case "$1" in
        default.png)           printf 'Contour — default' ;;
        relief.png)            printf 'Relief — black topography' ;;
        spectre.png)           printf 'Spectre — monochrome figure' ;;
        amber.png)             printf 'Amber — warm abstract' ;;
        unsplash-mountain.jpg) printf 'Unsplash — alpine fog / monochrome' ;;
        unsplash-neon.jpg)     printf 'Unsplash — neon alley / cyber' ;;
        *)                     printf '%s' "$1" ;;
    esac
}

while :; do
    mapfile -t files < <(find "$wall_dir" -maxdepth 1 -type f \( -iname '*.png' -o -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.webp' \) -printf '%f\n' | sort)
    menu=''
    for file in "${files[@]}"; do
        menu+="$file  $(label_for "$file")"$'\n'
    done
    if [[ ! -f "$wall_dir/unsplash-mountain.jpg" || ! -f "$wall_dir/unsplash-neon.jpg" ]]; then
        menu+="__fetch__  Download curated Unsplash pack"$'\n'
    fi

    selection="$(printf '%s' "$menu" | rofi -dmenu -i -p 'Wallpaper' -no-custom -theme "$rofi_theme" || true)"
    [[ -n "$selection" ]] || exit 0
    file="${selection%%  *}"

    if [[ "$file" == __fetch__ ]]; then
        /usr/bin/env bash "$fetcher" || true
        continue
    fi

    [[ -f "$wall_dir/$file" ]] || exit 1
    ln -sfn "$file" "$wall_dir/current"
    /usr/bin/env bash "$setter"
    command -v notify-send >/dev/null 2>&1 && notify-send -a kali-clean 'Wallpaper' "$(label_for "$file")" >/dev/null 2>&1 || true
    exit 0
done
