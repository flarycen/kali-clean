#!/usr/bin/env bash
set -Eeuo pipefail

theme=${1:-}
quiet=${2:-}
base="$HOME/.config/kali-clean"
theme_dir="$base/themes/$theme"
current="$base/current"
state_file="$base/theme"

case "$theme" in
    obsidian|neon) ;;
    *) printf 'usage: %s {obsidian|neon}\n' "${0##*/}" >&2; exit 2 ;;
esac

[[ -d "$theme_dir" ]] || { printf 'missing theme: %s\n' "$theme_dir" >&2; exit 1; }

ln -sfn "themes/$theme" "$current"
printf '%s\n' "$theme" > "$state_file"

# Alacritty watches its main config reliably; touching it makes imported-theme
# changes visible immediately even on versions that do not follow a changed symlink.
[[ ! -f "$HOME/.config/alacritty/alacritty.toml" ]] || touch "$HOME/.config/alacritty/alacritty.toml"

# Keep Firefox chrome in the same palette when profiles already exist. Firefox
# needs a restart to fully repaint chrome after a theme change.
profiles_ini="$HOME/.mozilla/firefox/profiles.ini"
if [[ -f "$profiles_ini" && -f "$theme_dir/firefox-theme.css" ]]; then
    while IFS= read -r line; do
        [[ $line == Path=* ]] || continue
        profile_path="${line#Path=}"
        if [[ "$profile_path" = /* ]]; then
            profile_dir="$profile_path"
        else
            profile_dir="$HOME/.mozilla/firefox/$profile_path"
        fi
        [[ -d "$profile_dir" ]] || continue
        mkdir -p "$profile_dir/chrome"
        cp -f -- "$theme_dir/firefox-theme.css" "$profile_dir/chrome/kali-clean-theme.css"
    done < "$profiles_ini"
fi

# Existing tmux servers should adopt the theme without killing sessions.
if command -v tmux >/dev/null 2>&1 && tmux list-sessions >/dev/null 2>&1; then
    tmux source-file "$HOME/.tmux.conf" >/dev/null 2>&1 || true
fi

# Dunst has no portable live theme reload, so restart only the user's daemon.
if command -v dunst >/dev/null 2>&1 && [[ -n "${DISPLAY:-}" ]]; then
    pkill -x dunst >/dev/null 2>&1 || true
    nohup dunst -config "$current/dunstrc" >"${XDG_STATE_HOME:-$HOME/.local/state}/kali-clean/dunst.log" 2>&1 &
fi

# i3 reloads the included theme fragment and restarts its bar in place.
if command -v i3-msg >/dev/null 2>&1 && [[ -n "${I3SOCK:-}${DISPLAY:-}" ]]; then
    i3-msg reload >/dev/null 2>&1 || true
fi

if [[ "$quiet" != --quiet ]] && command -v notify-send >/dev/null 2>&1; then
    case "$theme" in
        obsidian) label='Obsidian — minimal' ;;
        neon)     label='Neon — full aesthetic' ;;
    esac
    notify-send -a kali-clean 'Theme applied' "$label" >/dev/null 2>&1 || true
fi
