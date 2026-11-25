# kali-clean — zsh
# Two-line prompt: execution timestamp, VPN IP and path. Everything you type is
# bold white so commands stand out in screenshots. No framework required.

# ------------------------------------------------------------------ PATH / env
export PIPX_HOME="${PIPX_HOME:-$HOME/.local/share/pipx}"
export PIPX_BIN_DIR="${PIPX_BIN_DIR:-$HOME/.local/bin}"

typeset -U path PATH
path=(
    "$HOME/.local/bin"
    "$HOME/.local/share/kali-clean/bin"
    "$HOME/go/bin"
    "$HOME/.cargo/bin"
    /usr/local/sbin /usr/local/bin /usr/sbin /usr/bin /sbin /bin
    $path
)
export PATH

export EDITOR="${EDITOR:-$(command -v nvim 2>/dev/null || command -v vim 2>/dev/null || printf vi)}"
export VISUAL="$EDITOR"
export BROWSER="${BROWSER:-firefox-esr}"
export TERMINAL="${TERMINAL:-alacritty}"
export PAGER="${PAGER:-less}"
export LESS='-R -F -X -i'
# Readable, monochrome man pages.
export GROFF_NO_SGR=1
export LESS_TERMCAP_md=$'\e[1;97m' LESS_TERMCAP_me=$'\e[0m'
export LESS_TERMCAP_us=$'\e[4;37m' LESS_TERMCAP_ue=$'\e[0m'
export LESS_TERMCAP_so=$'\e[30;47m' LESS_TERMCAP_se=$'\e[0m'
export LESS_TERMCAP_mb=$'\e[1;31m'

# Docker-compatible clients (bloodhound-cli etc.) can use a rootless Podman socket.
if [[ -z "${DOCKER_HOST:-}" && -n "${XDG_RUNTIME_DIR:-}" && -S "$XDG_RUNTIME_DIR/podman/podman.sock" ]]; then
    export DOCKER_HOST="unix://$XDG_RUNTIME_DIR/podman/podman.sock"
fi

[[ -o interactive ]] || return 0

# ------------------------------------------------------------------ history
HISTFILE="$HOME/.zsh_history"
HISTSIZE=100000
SAVEHIST=100000
setopt EXTENDED_HISTORY SHARE_HISTORY HIST_IGNORE_DUPS HIST_IGNORE_SPACE
setopt HIST_REDUCE_BLANKS HIST_VERIFY HIST_EXPIRE_DUPS_FIRST

# ------------------------------------------------------------------ options
setopt AUTO_CD AUTO_PUSHD PUSHD_IGNORE_DUPS PUSHD_SILENT INTERACTIVE_COMMENTS
setopt PROMPT_SUBST NO_BEEP
# URLs and arguments often contain ? [ ] *; never abort on an unmatched glob.
unsetopt NOMATCH
WORDCHARS=${WORDCHARS//\/}

# ------------------------------------------------------------------ completion
_kc_cache="${XDG_CACHE_HOME:-$HOME/.cache}/zsh"
[[ -d "$_kc_cache" ]] || mkdir -p -- "$_kc_cache"
(( $+commands[dircolors] )) && eval "$(dircolors -b)"
autoload -Uz compinit
compinit -i -d "$_kc_cache/zcompdump-$ZSH_VERSION"
zstyle ':completion:*' menu select
zstyle ':completion:*' matcher-list 'm:{a-zA-Z}={A-Za-z}' 'r:|[._-]=* r:|=*'
zstyle ':completion:*' list-colors "${(s.:.)LS_COLORS}"
zstyle ':completion:*' group-name ''
zstyle ':completion:*:descriptions' format '%F{8}-- %d --%f'
zstyle ':completion:*' use-cache on
zstyle ':completion:*' cache-path "$_kc_cache/completion"

# ------------------------------------------------------------------ keys
bindkey -e
autoload -Uz up-line-or-beginning-search down-line-or-beginning-search
zle -N up-line-or-beginning-search
zle -N down-line-or-beginning-search
bindkey '^[[A' up-line-or-beginning-search
bindkey '^[OA' up-line-or-beginning-search
bindkey '^[[B' down-line-or-beginning-search
bindkey '^[OB' down-line-or-beginning-search
bindkey '^[[1;5C' forward-word
bindkey '^[[1;5D' backward-word
bindkey '^[[H' beginning-of-line
bindkey '^[OH' beginning-of-line
bindkey '^[[1~' beginning-of-line
bindkey '^[[F' end-of-line
bindkey '^[OF' end-of-line
bindkey '^[[4~' end-of-line
bindkey '^[[3~' delete-char
bindkey '^[[3;5~' kill-word
bindkey '^H' backward-kill-word
bindkey '^[[Z' reverse-menu-complete

# Esc Esc: toggle "sudo " at the start of the line (or of the last command).
_kc_sudo_toggle() {
    [[ -z $BUFFER ]] && BUFFER="$(fc -ln -1)"
    if [[ $BUFFER == sudo\ * ]]; then
        BUFFER="${BUFFER#sudo }"
    else
        BUFFER="sudo $BUFFER"
    fi
    CURSOR=${#BUFFER}
}
zle -N _kc_sudo_toggle
bindkey '\e\e' _kc_sudo_toggle

# ------------------------------------------------------------------ plugins
if [[ -r /usr/share/zsh-autosuggestions/zsh-autosuggestions.zsh ]]; then
    source /usr/share/zsh-autosuggestions/zsh-autosuggestions.zsh
    ZSH_AUTOSUGGEST_HIGHLIGHT_STYLE='fg=8'
fi

export FZF_DEFAULT_OPTS="--height=40% --layout=reverse \
--color=bg:#060606,bg+:#1f1f1f,fg:#a1a1aa,fg+:#ffffff,hl:#ffffff,hl+:#ffffff \
--color=info:#71717a,prompt:#ffffff,pointer:#ffffff,marker:#ffffff,spinner:#71717a,header:#71717a,border:#1f1f1f"
if (( $+commands[fzf] )); then
    if fzf --zsh >/dev/null 2>&1; then
        source <(fzf --zsh)
    else
        [[ -r /usr/share/doc/fzf/examples/key-bindings.zsh ]] && source /usr/share/doc/fzf/examples/key-bindings.zsh
        [[ -r /usr/share/doc/fzf/examples/completion.zsh ]] && source /usr/share/doc/fzf/examples/completion.zsh
    fi
fi

(( $+commands[zoxide] )) && eval "$(zoxide init zsh)"

# Everything typed on the command line is bold (bold renders as pure white).
# Pasted text is not highlighted, so pasted commands look the same in screenshots.
zle_highlight=(default:bold paste:none region:standout isearch:underline special:standout suffix:bold)

# ------------------------------------------------------------------ prompt
# ┌─[2026-11-25 14:32:07]─[10.10.14.5]─[~/htb/machines]
# └─$ nmap -sCV 10.10.11.23
# The timestamp is refreshed when you press Enter, so it records when the
# command actually ran, not when the prompt was drawn.
_kc_vpn_ip() {
    # Same preference as the bars: tun, then wg, tap, ppp, vpn, tailscale.
    local line iface addr p best='' rank best_rank=99
    local -a fields prefixes=(tun wg tap ppp vpn tailscale)
    for line in ${(f)"$(command ip -4 -o addr show 2>/dev/null)"}; do
        fields=(${=line})
        iface=$fields[2]
        addr=${fields[4]%%/*}
        [[ -n $addr && $addr != 127.* ]] || continue
        rank=0
        for p in $prefixes; do
            (( ++rank ))
            [[ $iface == ${p}* ]] && break
        done
        [[ $iface == ${prefixes[$rank]}* ]] || continue
        if (( rank < best_rank )); then
            best=$addr
            best_rank=$rank
        fi
    done
    REPLY=$best
}

_kc_prompt_precmd() {
    local ec=$?
    _kc_vpn_ip
    local top='%F{8}┌─[%f%F{15}%D{%Y-%m-%d %H:%M:%S}%f%F{8}]'
    [[ -n $REPLY ]] && top+="─[%f%F{15}${REPLY}%f%F{8}]"
    top+='─[%f%B%F{15}%~%f%b%F{8}]'
    (( ec )) && top+="─[%f%F{9}✗ ${ec}%f%F{8}]"
    PROMPT="${top}%f"$'\n''%F{8}└─%f%B%(!.%F{9}#.%F{15}$)%f%b '
    RPROMPT=''
}

_kc_prompt_line_finish() {
    zle reset-prompt
}

autoload -Uz add-zsh-hook add-zle-hook-widget
add-zle-hook-widget line-finish _kc_prompt_line_finish

# ------------------------------------------------------------------ Mod+Enter cwd
# i3's Mod+Enter reads this per-window cache to open a terminal in the same dir.
_KC_CWD_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/kali-clean/cwd"
[[ -d "$_KC_CWD_DIR" ]] || mkdir -p -- "$_KC_CWD_DIR"
_kc_track_terminal_cwd() {
    [[ -n "${DISPLAY:-}" ]] && (( $+commands[xdotool] )) || return 0
    local wid
    wid="$(xdotool getactivewindow 2>/dev/null)" || return 0
    [[ $wid == <-> ]] || return 0
    ln -sfn -- "$PWD" "$_KC_CWD_DIR/$wid" 2>/dev/null
    return 0
}
add-zsh-hook chpwd _kc_track_terminal_cwd
add-zsh-hook precmd _kc_track_terminal_cwd

# ------------------------------------------------------------------ persistent vars
# `export ip=10.10.11.23` is shared with every zsh/tmux shell until unset.
# Helpers: persistedenv, persistenv NAME [VALUE], unpersistenv NAME.
[[ -r "$HOME/.config/kali-clean/env-sync.zsh" ]] && source "$HOME/.config/kali-clean/env-sync.zsh"

# ------------------------------------------------------------------ aliases
alias ls='ls --color=auto --group-directories-first'
alias ll='ls -lah'
alias la='ls -A'
alias l='ls -CF'
alias grep='grep --color=auto'
alias diff='diff --color=auto'
alias ip='ip --color=auto'
alias ports='ss -tulpn'
alias py='python3'
alias venv='python3 -m venv .venv && source .venv/bin/activate'
(( $+commands[batcat] && ! $+commands[bat] )) && alias bat='batcat'
(( $+commands[fdfind] && ! $+commands[fd] )) && alias fd='fdfind'
(( $+commands[eza] )) && alias lt='eza --tree --level=2 --group-directories-first'

# ------------------------------------------------------------------ helpers
_kc_info() { python3 "$HOME/.config/kali-clean/kcinfo.py" "$@" }

vpnip()   { _kc_info vpn }
copyvpn() { _kc_info copy vpn && print -r -- "copied $(_kc_info vpn)" }

# target [IP]  set or show the target ($ip), shared with every shell and the bars.
target() {
    if (( $# )); then
        export ip="$1"
        print -r -- "ip=$ip"
    else
        print -r -- "${ip:-no target set (target 10.10.11.23)}"
    fi
}

# sudo: also find kali-clean's ~/.local/bin commands (sudo ntlmrelayx.py, sudo smbserver.py).
sudo() {
    local resolved
    if (( $# )) && [[ $1 != -* ]]; then
        resolved="$(whence -p -- "$1" 2>/dev/null)"
        if [[ -n $resolved && $resolved == "$HOME"/* ]]; then
            command sudo -- "$resolved" "${@:2}"
            return
        fi
    fi
    command sudo "$@"
}

# serve [DIR] [PORT]  HTTP server + ready-to-paste download commands for the VPN IP.
serve() {
    local dir="${1:-.}" port="${2:-8000}" host f n=0
    [[ -d $dir ]] || { print -u2 "serve: not a directory: $dir"; return 1; }
    host="$(_kc_info vpn)"; host="${host:-127.0.0.1}"
    print -P "%F{8}serving%f %B$dir%b %F{8}on%f %Bhttp://$host:$port/%b"
    for f in "$dir"/*(N.); do
        (( n++ < 12 )) || break
        f="${f:t}"
        print -r -- "  wget http://$host:$port/$f"
        print -r -- "  iwr http://$host:$port/$f -OutFile $f"
    done
    (cd -- "$dir" && python3 -m http.server "$port")
}

# addhost IP NAME...  append to /etc/hosts (asks for sudo), skips duplicates.
addhost() {
    (( $# >= 2 )) || { print -u2 'usage: addhost 10.10.11.23 dc01.corp.local corp.local'; return 2; }
    local line="$*"
    if grep -qxF -- "$line" /etc/hosts; then
        print -r -- "already present: $line"
    else
        print -r -- "$line" | command sudo tee -a /etc/hosts >/dev/null && print -r -- "added: $line"
    fi
}

mkcd() { mkdir -p -- "$1" && cd -- "$1" }

extract() {
    local f
    for f in "$@"; do
        [[ -f $f ]] || { print -u2 "extract: no such file: $f"; continue; }
        case ${f:l} in
            *.tar.gz|*.tgz)   tar -xzf "$f" ;;
            *.tar.bz2|*.tbz2) tar -xjf "$f" ;;
            *.tar.xz|*.txz)   tar -xJf "$f" ;;
            *.tar.zst)        tar --zstd -xf "$f" ;;
            *.tar)            tar -xf "$f" ;;
            *.zip|*.jar)      unzip -o "$f" ;;
            *.7z)             7z x "$f" ;;
            *.rar)            7z x "$f" ;;
            *.gz)             gunzip -k "$f" ;;
            *.bz2)            bunzip2 -k "$f" ;;
            *.xz)             unxz -k "$f" ;;
            *)                print -u2 "extract: unknown archive: $f" ;;
        esac
    done
}

# ------------------------------------------------------------------ last
# The prompt hook must run first so it sees the real exit status.
precmd_functions=(_kc_prompt_precmd ${precmd_functions:#_kc_prompt_precmd})
