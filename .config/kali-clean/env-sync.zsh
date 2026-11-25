# kali-clean — persistent exported variables for zsh/tmux.
# `export ip=10.10.11.23` (or any variable you export after the shell started)
# is shared with every existing and new zsh/tmux shell until changed or unset.
#
#   persistedenv              list what is shared
#   persistenv NAME [VALUE]   share a variable explicitly (--force for *TOKEN* etc.)
#   unpersistenv NAME         stop sharing a variable
#
# Python only runs when this shell's exported variables or the shared file
# actually changed, so the prompt stays instant.

[[ -o interactive ]] || return 0

_KC_ENV_HELPER="$HOME/.config/kali-clean/env-sync.py"
_KC_ENV_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/kali-clean/session.env"
[[ -r "$_KC_ENV_HELPER" ]] && (( $+commands[python3] )) || return 0
zmodload -F zsh/stat b:zstat 2>/dev/null || return 0

typeset -g _kc_env_sig='' _kc_env_stamp=''

_kc_env_eval() {
    local output
    output="$(python3 "$_KC_ENV_HELPER" --shell-pid "$$" "$@")" || return $?
    [[ -n "$output" ]] && eval "$output"
    return 0
}

# Cheap fingerprint of this shell's exported variables (no subshells).
_kc_env_signature() {
    local name sig=''
    for name in ${(ok)parameters[(R)*export*]}; do
        case $name in
            _|PWD|OLDPWD|SHLVL|COLUMNS|LINES) continue ;;
        esac
        sig+="${name}=${(P)name}"$'\0'
    done
    REPLY=$sig
}

# Shared file identity: inode + size + mtime (it is replaced atomically).
_kc_env_file_stamp() {
    local -A st
    if zstat -H st -- "$_KC_ENV_FILE" 2>/dev/null; then
        REPLY="${st[inode]}:${st[size]}:${st[mtime]}"
    else
        REPLY=''
    fi
}

_kc_env_remember() {
    _kc_env_signature; _kc_env_sig=$REPLY
    _kc_env_file_stamp; _kc_env_stamp=$REPLY
}

_kc_env_sync() {
    local sig stamp
    _kc_env_signature; sig=$REPLY
    _kc_env_file_stamp; stamp=$REPLY
    if [[ $sig != "$_kc_env_sig" || $stamp != "$_kc_env_stamp" ]]; then
        _kc_env_eval sync
        _kc_env_remember
    fi
    return 0
}

persistenv() {
    local force='' name value
    if [[ ${1:-} == --force ]]; then
        force='--force'
        shift
    fi
    name=${1:-}
    if [[ -z "$name" ]]; then
        print -u2 'usage: persistenv [--force] NAME [VALUE]'
        return 2
    fi
    if (( $# >= 2 )); then
        value=$2
    elif (( ${+parameters[$name]} )); then
        value="${(P)name}"
    else
        print -u2 "'$name' is not set; provide a value."
        return 2
    fi
    _kc_env_eval set ${force:+--force} "$name" "$value" && _kc_env_remember
}

unpersistenv() {
    local name=${1:-}
    [[ -n "$name" ]] || { print -u2 'usage: unpersistenv NAME'; return 2; }
    python3 "$_KC_ENV_HELPER" --shell-pid "$$" unpersist "$name" && _kc_env_remember
}

persistedenv() {
    python3 "$_KC_ENV_HELPER" --shell-pid "$$" list
}

_kc_env_eval init
_kc_env_remember

# precmd publishes changes after each command; line-finish imports changes
# from other panes right before the next command runs (so $ip expands right).
autoload -Uz add-zsh-hook add-zle-hook-widget
add-zsh-hook precmd _kc_env_sync
add-zle-hook-widget line-finish _kc_env_sync
