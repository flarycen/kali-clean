#!/usr/bin/env bash
# Apply ~/.wallpaper/current (a symlink chosen with Mod+Shift+B).
#   set-wallpaper.sh          apply it
#   set-wallpaper.sh --check  only verify it is a readable image
set -Eeuo pipefail

wall_dir="$HOME/.wallpaper"
current="$wall_dir/current"
default_name='contour.png'

mkdir -p -- "$wall_dir"

target=''
if [[ -L "$current" ]]; then
    target="$(readlink -f -- "$current" 2>/dev/null || true)"
fi

if [[ -z "$target" || ! -f "$target" ]]; then
    if [[ -f "$wall_dir/$default_name" ]]; then
        ln -sfn -- "$default_name" "$current"
        target="$wall_dir/$default_name"
    else
        # Nothing to show: a solid near-black root window is still correct.
        command -v xsetroot >/dev/null 2>&1 && xsetroot -solid '#060606' 2>/dev/null || true
        exit 0
    fi
fi

if [[ ${1:-} == --check ]]; then
    [[ -r "$target" ]] || exit 1
    file --brief --mime-type -- "$target" | grep -Eq '^image/'
    exit $?
fi

if command -v feh >/dev/null 2>&1; then
    exec feh --no-fehbg --bg-fill -- "$target"
fi
command -v xsetroot >/dev/null 2>&1 && xsetroot -solid '#060606' 2>/dev/null || true
