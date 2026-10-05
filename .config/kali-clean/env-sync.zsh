# kali-clean persistent exported variables for zsh/tmux.
# `export ip=10.10.11.23` (or any other newly-created exported variable) is
# synchronized across existing/new zsh and tmux sessions until changed/unset.

[[ -o interactive ]] || return 0

_KC_ENV_HELPER="$HOME/.config/kali-clean/env-sync.py"
if [[ -x "$_KC_ENV_HELPER" ]] && command -v python3 >/dev/null 2>&1; then
    _kc_env_eval() {
        local output
        output="$(python3 "$_KC_ENV_HELPER" --shell-pid "$$" "$@")" || return $?
        [[ -n "$output" ]] && eval "$output"
    }

    _kc_env_sync() {
        _kc_env_eval sync
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
        elif typeset -p "$name" >/dev/null 2>&1; then
            value="${(P)name}"
        else
            print -u2 "'$name' is not set; provide a value."
            return 2
        fi
        if [[ -n "$force" ]]; then
            _kc_env_eval set --force "$name" "$value"
        else
            _kc_env_eval set "$name" "$value"
        fi
    }

    unpersistenv() {
        local name=${1:-}
        [[ -n "$name" ]] || { print -u2 'usage: unpersistenv NAME'; return 2; }
        python3 "$_KC_ENV_HELPER" --shell-pid "$$" unpersist "$name"
    }

    persistedenv() {
        python3 "$_KC_ENV_HELPER" --shell-pid "$$" list
    }

    _kc_env_eval init

    # Publish after each command. line-finish runs after Enter but before zsh
    # executes the entered line, allowing another pane's update to be imported
    # before expansion of variables in that command. Hooks do not replace ZLE
    # widgets, so autosuggestions and syntax highlighting keep working normally.
    autoload -Uz add-zsh-hook add-zle-hook-widget
    add-zsh-hook precmd _kc_env_sync
    add-zle-hook-widget line-finish _kc_env_sync
fi
