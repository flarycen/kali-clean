#!/usr/bin/env bash
set -Eeuo pipefail

wall_dir="$HOME/.wallpaper"
current="$wall_dir/current"
default="$wall_dir/default.png"

mkdir -p "$wall_dir"

if [[ -L "$current" ]]; then
    target="$(readlink -f -- "$current" 2>/dev/null || true)"
else
    target=''
fi

if [[ -z "$target" || ! -f "$target" ]]; then
    [[ -f "$default" ]] || exit 1
    ln -sfn default.png "$current"
    target="$default"
fi

if [[ ${1:-} == --check ]]; then
    [[ -r "$target" ]] || exit 1
    file --brief --mime-type "$target" | grep -Eq '^image/'
    exit $?
fi

command -v feh >/dev/null 2>&1 || exit 1
exec feh --no-fehbg --bg-fill "$target"
