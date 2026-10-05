# kali-clean zsh configuration

export PIPX_HOME="${PIPX_HOME:-$HOME/.local/share/pipx}"
export PIPX_BIN_DIR="${PIPX_BIN_DIR:-$HOME/.local/bin}"

# Keep every user-installed CLI reachable from any directory while preserving
# the standard Kali command paths. `typeset -U` removes duplicate path entries.
typeset -U path PATH
path=(
    "$PIPX_BIN_DIR"
    "$HOME/.local/share/kali-clean/bin"
    "$HOME/.cargo/bin"
    "$HOME/go/bin"
    /usr/local/sbin /usr/local/bin /usr/sbin /usr/bin /sbin /bin
    $path
)
export PATH
export EDITOR="${EDITOR:-$(command -v nvim 2>/dev/null || command -v vim 2>/dev/null || printf vi)}"
export VISUAL="$EDITOR"
export BROWSER="${BROWSER:-firefox-esr}"
export TERMINAL="${TERMINAL:-alacritty}"
export PAGER="${PAGER:-less}"
export LESS='-R -F -X'

# Point Docker-compatible API clients (including bloodhound-cli) at the
# per-user Podman socket when it is active. This is
# deliberately shell-local and only activates when no DOCKER_HOST was supplied.
if [[ -z "${DOCKER_HOST:-}" && -n "${XDG_RUNTIME_DIR:-}" && -S "$XDG_RUNTIME_DIR/podman/podman.sock" ]]; then
    export DOCKER_HOST="unix://$XDG_RUNTIME_DIR/podman/podman.sock"
fi

HISTFILE="$HOME/.zsh_history"
HISTSIZE=100000
SAVEHIST=100000
setopt APPEND_HISTORY INC_APPEND_HISTORY SHARE_HISTORY HIST_IGNORE_DUPS HIST_REDUCE_BLANKS HIST_VERIFY
setopt AUTO_CD AUTO_PUSHD PUSHD_IGNORE_DUPS INTERACTIVE_COMMENTS
# Pentest URLs/arguments often contain ?, [, ], and *. Do not abort commands just
# because an unmatched argument looks like a zsh glob.
unsetopt NOMATCH

bindkey -e

# Oh My Zsh is installed by install.sh, but keep the shell fully usable if it is absent.
export ZSH="$HOME/.oh-my-zsh"
ZSH_THEME=""
plugins=(git sudo extract colored-man-pages)
[[ -r "$ZSH/oh-my-zsh.sh" ]] && source "$ZSH/oh-my-zsh.sh"

[[ -r /usr/share/zsh-autosuggestions/zsh-autosuggestions.zsh ]] && source /usr/share/zsh-autosuggestions/zsh-autosuggestions.zsh
ZSH_AUTOSUGGEST_HIGHLIGHT_STYLE='fg=242'

if command -v zoxide >/dev/null 2>&1; then
    eval "$(zoxide init zsh)"
fi

if command -v direnv >/dev/null 2>&1; then
    eval "$(direnv hook zsh)"
fi

[[ -r /usr/share/doc/fzf/examples/key-bindings.zsh ]] && source /usr/share/doc/fzf/examples/key-bindings.zsh
[[ -r /usr/share/doc/fzf/examples/completion.zsh ]] && source /usr/share/doc/fzf/examples/completion.zsh

# Persist newly-created exported variables across all zsh/tmux shells.
# Example: `export ip=10.10.11.23`; see `persistedenv`, `persistenv`, `unpersistenv`.
[[ -r "$HOME/.config/kali-clean/env-sync.zsh" ]] && source "$HOME/.config/kali-clean/env-sync.zsh"

# Track the active terminal's real shell directory. Alacritty itself does not
# change its process cwd when the shell runs `cd`, so i3's Mod+Return helper
# reads this small per-window cache before falling back to /proc.
_KC_CWD_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/kali-clean/cwd"
mkdir -p -- "$_KC_CWD_DIR"
_kc_track_terminal_cwd() {
    [[ -n "${DISPLAY:-}" ]] || return 0
    command -v xdotool >/dev/null 2>&1 || return 0
    local wid
    wid="$(xdotool getactivewindow 2>/dev/null)" || return 0
    case "$wid" in
        ''|*[!0-9]*) return 0 ;;
    esac
    ln -sfn -- "$PWD" "$_KC_CWD_DIR/$wid"
}
autoload -Uz add-zsh-hook
add-zsh-hook chpwd _kc_track_terminal_cwd
add-zsh-hook precmd _kc_track_terminal_cwd

# Prompt follows the active desktop theme and updates on the next prompt.
_kc_set_prompt_theme() {
    local theme
    theme="$(cat "$HOME/.config/kali-clean/theme" 2>/dev/null || printf obsidian)"
    if [[ "$theme" == neon ]]; then
        PROMPT='%F{81}%n@%m%f %F{141}%~%f %(?..%F{203}[%?]%f )%F{117}❯%f '
    else
        PROMPT='%F{244}%n@%m%f %F{250}%~%f %(?..%F{203}[%?]%f )%F{252}❯%f '
    fi
    RPROMPT=''
}
add-zsh-hook precmd _kc_set_prompt_theme
_kc_set_prompt_theme

alias ll='ls -lah'
alias la='ls -A'
alias grep='grep --color=auto'
alias ports='ss -tulpn'
alias py='python3'
alias venv='python3 -m venv .venv'
alias serve='python3 -m http.server'

if command -v eza >/dev/null 2>&1; then
    alias ls='eza --group-directories-first'
    alias ll='eza -lah --group-directories-first --git'
fi

if command -v batcat >/dev/null 2>&1; then
    alias bat='batcat'
fi

if ! command -v fd >/dev/null 2>&1 && command -v fdfind >/dev/null 2>&1; then
    alias fd='fdfind'
fi

vpnip() {
    python3 "$HOME/.config/i3/status.py" --vpn-ip
}

copyvpn() {
    local addr
    addr="$(vpnip)"
    if [[ -z "$addr" ]]; then
        print -u2 'No VPN IPv4 address detected.'
        return 1
    fi
    print -rn -- "$addr" | xclip -selection clipboard -in
    print -- "Copied $addr"
}

# Keep syntax-highlighting last so all widgets and bindings are already defined.
[[ -r /usr/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh ]] && source /usr/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh
