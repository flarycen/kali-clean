#!/usr/bin/env bash
# Optional curated Unsplash pack. Failures never affect the desktop itself.
set -Eeuo pipefail

wall_dir="$HOME/.wallpaper"
mkdir -p "$wall_dir"
command -v curl >/dev/null 2>&1 || { printf 'curl is required\n' >&2; exit 1; }

fetch() {
    local name=$1 url=$2 tmp
    [[ -f "$wall_dir/$name" ]] && return 0
    tmp="$wall_dir/.${name}.part"
    if curl --fail --location --retry 3 --connect-timeout 10 --output "$tmp" "$url"; then
        mv -f -- "$tmp" "$wall_dir/$name"
    else
        rm -f -- "$tmp"
        return 1
    fi
}

ok=1
fetch 'unsplash-mountain.jpg' 'https://images.unsplash.com/photo-1511973652286-0a8edb588723?auto=format&fit=crop&w=2560&h=1440&q=85' || ok=0
fetch 'unsplash-neon.jpg' 'https://images.unsplash.com/photo-1561344640-2453889cde5b?auto=format&fit=crop&w=2560&h=1440&q=85' || ok=0

if (( ok )); then
    command -v notify-send >/dev/null 2>&1 && notify-send -a kali-clean 'Wallpapers' 'Curated Unsplash pack downloaded.' >/dev/null 2>&1 || true
else
    command -v notify-send >/dev/null 2>&1 && notify-send -u normal -a kali-clean 'Wallpapers' 'One or more Unsplash downloads failed; bundled wallpapers are unchanged.' >/dev/null 2>&1 || true
    exit 1
fi
