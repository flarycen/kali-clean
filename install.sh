#!/usr/bin/env bash
# kali-clean — one-shot Kali/i3 workstation installer.
# Inspired by xct/kali-clean and Pebl3/kali-clean.
# Run as your normal Kali user, never as root.

set -Eeuo pipefail
IFS=$'\n\t'

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/kali-clean"
readonly LOG_FILE="$STATE_DIR/install.log"
readonly BACKUP_ROOT="$STATE_DIR/backups"
readonly LOCAL_BIN="$HOME/.local/bin"
readonly MANAGED_BIN="$HOME/.local/share/kali-clean/bin"
readonly TOOLS_DIR="$HOME/tools"
readonly LAB_ROOT="$HOME/labs"

WALLPAPER_CHOICE='default.png'

# Required package names are centralized so the installer can validate the
# entire Kali package surface before it changes anything. Optional packages are
# best-effort and never make an otherwise healthy rolling snapshot fail.
readonly -a SYSTEM_PACKAGES=(
    kali-desktop-i3 kali-linux-default
    alacritty firefox-esr zsh tmux ncurses-term pipx python3 python3-pip python3-venv python3-dev
    ca-certificates curl wget git rsync unzip zip jq xz-utils tar gzip gnupg file xdg-utils iproute2
    build-essential pkg-config gcc make golang-go cargo nodejs npm ruby-full
    feh rofi picom dunst libnotify-bin lxpolkit thunar flameshot network-manager-gnome
    arc-theme papirus-icon-theme fonts-jetbrains-mono fonts-font-awesome
    xclip xsel xdotool unclutter i3lock pulseaudio-utils playerctl brightnessctl
    openvpn tcpdump network-manager-openvpn network-manager-openvpn-gnome wireguard-tools
    fzf ripgrep bat fd-find
)

readonly -a QOL_PACKAGES=(
    eza zoxide direnv blueman maim neovim btop ranger tree pv shellcheck fastfetch python-is-python3
)

readonly -a SECURITY_PACKAGES=(
    nmap masscan rustscan autorecon netcat-traditional ncat nfs-common
    ffuf gobuster feroxbuster dirsearch wfuzz whatweb nikto burpsuite wpscan sqlmap commix
    hydra john hashcat responder smbclient smbmap enum4linux-ng samba-common-bin
    impacket-scripts python3-impacket netexec evil-winrm evil-winrm-py certipy-ad coercer
    bloodhound bloodhound-ce-python bloodyad
    krb5-user krb5-config libkrb5-dev ldap-utils libsasl2-modules-gssapi-mit bind9-dnsutils
    chisel ligolo-ng socat rlwrap sshpass proxychains4 sshuttle freerdp-x11
    dnsrecon snmp onesixtyone smtp-user-enum swaks
    redis-tools default-mysql-client postgresql-client sqlite3
    penelope payloadsallthethings metasploit-framework exploitdb peass
    libimage-exiftool-perl steghide binwalk3 7zip xxd
    wordlists seclists cupp cewl crunch
    podman podman-compose docker-compose
)

readonly -a OPTIONAL_SECURITY_PACKAGES=(
    kerbrute dnsenum fierce ftp telnet ipmitool eyewitness wafw00f nuclei subfinder amass httpx-toolkit bopscrk
    ldeep adidnsdump mitm6 azurehound sharphound rubeus powershell powersploit pkinittools pywhisker
    kali-tools-windows-resources windows-binaries chisel-common-binaries ligolo-ng-common-binaries
)

mkdir -p "$STATE_DIR" "$BACKUP_ROOT" "$LOCAL_BIN" "$MANAGED_BIN" "$TOOLS_DIR"
export PATH="$LOCAL_BIN:$MANAGED_BIN:$PATH"
touch "$LOG_FILE"
exec > >(tee -a "$LOG_FILE") 2>&1

C_RESET='\033[0m'
C_BOLD='\033[1m'
C_RED='\033[31m'
C_GREEN='\033[32m'
C_YELLOW='\033[33m'
C_BLUE='\033[34m'

info() { printf '%b[+]%b %s\n' "$C_BLUE" "$C_RESET" "$*"; }
ok()   { printf '%b[✓]%b %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn() { printf '%b[!]%b %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
die()  { printf '%b[x]%b %s\n' "$C_RED" "$C_RESET" "$*" >&2; exit 1; }

on_error() {
    local exit_code=$?
    local line_no=${1:-unknown}
    printf '%b[x]%b Installation failed at line %s (exit %s).\n' "$C_RED" "$C_RESET" "$line_no" "$exit_code" >&2
    printf '    Log: %s\n' "$LOG_FILE" >&2
    exit "$exit_code"
}
trap 'on_error "$LINENO"' ERR

choose_wallpaper() {
    local input
    if [[ ! -t 0 ]]; then
        WALLPAPER_CHOICE='default.png'
        return 0
    fi

    cat <<'MENU'

Wallpaper
---------
  1  Contour (default)
  2  Relief — black 3D topography
  3  Spectre — monochrome figure
  4  Amber — warm abstract
MENU
    read -r -p 'Wallpaper [1]: ' input || input=''
    case "${input:-1}" in
        1) WALLPAPER_CHOICE='default.png' ;;
        2) WALLPAPER_CHOICE='relief.png' ;;
        3) WALLPAPER_CHOICE='spectre.png' ;;
        4) WALLPAPER_CHOICE='amber.png' ;;
        *) warn "Unknown choice '$input'; using contour."; WALLPAPER_CHOICE='default.png' ;;
    esac
}

require_normal_user() {
    [[ ${EUID:-$(id -u)} -ne 0 ]] || die 'Do not run this installer as root. Run ./install.sh as your normal Kali user.'
    command -v sudo >/dev/null 2>&1 || die 'sudo is required.'
}


require_kali() {
    [[ -r /etc/os-release ]] || die 'Cannot identify the operating system.'
    # shellcheck disable=SC1091
    . /etc/os-release
    [[ ${ID:-} == kali ]] || die "This installer is intentionally limited to Kali Linux (detected: ${PRETTY_NAME:-unknown})."
}


prime_sudo() {
    info 'Requesting sudo access...'
    sudo -v
}


apt_refresh() {
    info 'Refreshing Kali package metadata...'
    if command -v kali-check-apt-sources >/dev/null 2>&1; then
        kali-check-apt-sources >/dev/null 2>&1 || warn 'Kali reports a possible APT source issue. The installer will not rewrite your sources.'
    fi
    sudo apt-get update
}


apt_has_package() {
    # `apt-cache show` can return metadata for packages that no longer have an
    # installable candidate in kali-rolling. Check the policy candidate instead.
    local candidate
    candidate="$(LC_ALL=C apt-cache policy "$1" 2>/dev/null | awk '/Candidate:/ {print $2; exit}')"
    [[ -n "$candidate" && "$candidate" != "(none)" ]]
}


apt_install_required() {
    local pkg
    local -a packages=("$@") missing=()

    for pkg in "${packages[@]}"; do
        apt_has_package "$pkg" || missing+=("$pkg")
    done
    ((${#missing[@]} == 0)) || die "Required Kali package(s) are unavailable in your configured repositories: ${missing[*]}"

    sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y -- "${packages[@]}"
}


apt_install_available() {
    local pkg
    local -a wanted=("$@") available=() unavailable=()

    for pkg in "${wanted[@]}"; do
        if apt_has_package "$pkg"; then
            available+=("$pkg")
        else
            unavailable+=("$pkg")
        fi
    done

    ((${#available[@]} == 0)) || sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y -- "${available[@]}"
    ((${#unavailable[@]} == 0)) || warn "Optional packages not present in this Kali repository were skipped: ${unavailable[*]}"
}


install_geist_mono() {
    local font_dir="$HOME/.local/share/fonts/Geist"
    local tmp_dir zip_path staged count

    info 'Installing Geist Mono (Pebl3-style typography)...'
    tmp_dir="$(mktemp -d)"
    zip_path="$tmp_dir/geist-font.zip"
    staged="$tmp_dir/staged"
    mkdir -p "$staged" "$tmp_dir/unpacked"

    if curl --fail --location --retry 3 --output "$zip_path" \
        'https://github.com/vercel/geist-font/releases/latest/download/geist-font.zip'; then
        if unzip -q "$zip_path" -d "$tmp_dir/unpacked"; then
            count=0
            while IFS= read -r -d '' font; do
                install -m 0644 "$font" "$staged/$(basename "$font")"
                count=$((count + 1))
            done < <(find "$tmp_dir/unpacked" -type f \( -iname 'GeistMono*.ttf' -o -iname 'GeistMono*.otf' \) -print0)

            if (( count > 0 )); then
                # Only replace our dedicated Geist directory after a valid archive
                # was unpacked. A failed download never destroys an existing font.
                rm -rf -- "$font_dir"
                mkdir -p "$font_dir"
                cp -a -- "$staged/." "$font_dir/"
                fc-cache -f "$font_dir" >/dev/null
                ok 'Geist Mono installed.'
            else
                warn 'The Geist release contained no recognized Geist Mono desktop fonts; JetBrains Mono will be used.'
            fi
        else
            warn 'The downloaded Geist archive could not be unpacked; keeping any existing fonts untouched.'
        fi
    else
        warn 'Could not download Geist Mono; JetBrains Mono will be used.'
    fi

    rm -rf -- "$tmp_dir"
}


backup_path() {
    local source_path=$1 backup_dir=$2 rel
    [[ -e "$source_path" || -L "$source_path" ]] || return 0

    rel="${source_path#$HOME/}"
    mkdir -p "$backup_dir/$(dirname "$rel")"
    cp -a -- "$source_path" "$backup_dir/$rel"
}


install_repo_dotfiles() {
    local stamp backup_dir name source target
    local -a config_dirs=(i3 alacritty rofi picom dunst gtk-3.0 firefox)

    stamp="$(date '+%Y%m%d-%H%M%S-%N')"
    backup_dir="$BACKUP_ROOT/$stamp"
    mkdir -p "$backup_dir" "$HOME/.config"

    info "Installing user dotfiles (backup: $backup_dir)..."

    for name in "${config_dirs[@]}"; do
        source="$SCRIPT_DIR/.config/$name"
        target="$HOME/.config/$name"
        [[ -e "$source" ]] || continue
        backup_path "$target" "$backup_dir"
        rm -rf -- "$target"
        cp -a -- "$source" "$target"
    done

    # Runtime state such as session.env lives beside the env-sync helpers.
    # Install only the shipped helper files so reruns never erase persisted vars.
    if [[ -d "$SCRIPT_DIR/.config/kali-clean" ]]; then
        mkdir -p "$HOME/.config/kali-clean"
        for name in env-sync.zsh env-sync.py; do
            source="$SCRIPT_DIR/.config/kali-clean/$name"
            target="$HOME/.config/kali-clean/$name"
            [[ -f "$source" ]] || continue
            backup_path "$target" "$backup_dir"
            if [[ "$name" == *.py ]]; then
                install -m 0755 "$source" "$target"
            else
                install -m 0644 "$source" "$target"
            fi
        done
    fi

    for name in .zshrc .tmux.conf .fehbg; do
        source="$SCRIPT_DIR/$name"
        target="$HOME/$name"
        [[ -e "$source" ]] || continue
        backup_path "$target" "$backup_dir"
        cp -a -- "$source" "$target"
    done

    if [[ -d "$SCRIPT_DIR/.wallpaper" ]]; then
        # Preserve any wallpapers the user added. Only the files shipped by this
        # project (and the current selector symlink) are managed by the installer.
        mkdir -p "$HOME/.wallpaper"
        backup_path "$HOME/.wallpaper/current" "$backup_dir"
        for name in default.png relief.png spectre.png amber.png; do
            source="$SCRIPT_DIR/.wallpaper/$name"
            target="$HOME/.wallpaper/$name"
            [[ -f "$source" ]] || continue
            backup_path "$target" "$backup_dir"
            install -m 0644 "$source" "$target"
        done
    fi

    # Git hosting/web uploads and some archive formats do not reliably preserve
    # executable bits. Enforce the runtime permissions we require instead of
    # trusting repository metadata.
    [[ ! -f "$HOME/.fehbg" ]] || chmod 0755 "$HOME/.fehbg"
    if [[ -d "$HOME/.config/i3/scripts" ]]; then
        find "$HOME/.config/i3/scripts" -maxdepth 1 -type f -name '*.sh' -exec chmod 0755 {} +
    fi
    if [[ -d "$HOME/.config/i3/blocks" ]]; then
        find "$HOME/.config/i3/blocks" -maxdepth 1 -type f -exec chmod 0755 {} +
    fi

    ok 'User dotfiles copied. No system configuration files were overwritten.'
}


apply_font_fallback() {
    local chosen='Geist Mono' file matched
    local -a files=(
        "$HOME/.config/i3/config"
        "$HOME/.config/alacritty/alacritty.toml"
        "$HOME/.config/rofi/config.rasi"
        "$HOME/.config/dunst/dunstrc"
        "$HOME/.config/gtk-3.0/settings.ini"
    )

    matched="$(fc-match -f '%{family}' 'Geist Mono' 2>/dev/null || true)"
    if [[ "$matched" != *Geist* ]]; then
        chosen='JetBrains Mono'
        warn 'Geist Mono is unavailable; applying the installed JetBrains Mono fallback.'
        for file in "${files[@]}"; do
            [[ -f "$file" ]] || continue
            sed -i 's/Geist Mono/JetBrains Mono/g' "$file"
        done
    fi
    ok "Desktop font: $chosen"
}


configure_login_shell() {
    local zsh_path
    zsh_path="$(command -v zsh)"
    [[ -n "$zsh_path" ]] || die 'zsh was installed but cannot be located.'
    grep -Fxq "$zsh_path" /etc/shells || die "Installed zsh is not listed in /etc/shells: $zsh_path"

    if [[ "$(getent passwd "$USER" | cut -d: -f7)" != "$zsh_path" ]]; then
        info "Setting zsh as the login shell for $USER..."
        sudo chsh -s "$zsh_path" "$USER"
    fi
}


configure_default_browser() {
    local desktop_file=''

    if [[ -f /usr/share/applications/firefox-esr.desktop ]]; then
        desktop_file='firefox-esr.desktop'
    elif [[ -f /usr/share/applications/firefox.desktop ]]; then
        desktop_file='firefox.desktop'
    fi

    if [[ -n "$desktop_file" ]]; then
        xdg-settings set default-web-browser "$desktop_file" >/dev/null 2>&1 || \
            warn 'Could not set Firefox as the default browser in the current session.'
    fi
}


install_firefox_customizations() {
    local source_dir="$SCRIPT_DIR/.config/firefox"
    local ini="$HOME/.mozilla/firefox/profiles.ini"
    local line profile_path absolute user_chrome user_content user_js

    [[ -d "$source_dir" ]] || return 0
    [[ -f "$ini" ]] || {
        warn 'Firefox has no profile yet. Launch Firefox once and rerun ./install.sh to apply browser chrome.'
        return 0
    }

    user_chrome="$source_dir/userChrome.css"
    user_content="$source_dir/userContent.css"
    user_js="$source_dir/user.js"

    while IFS= read -r line; do
        [[ $line == Path=* ]] || continue
        profile_path="${line#Path=}"
        [[ -n "$profile_path" ]] || continue

        if [[ "$profile_path" = /* ]]; then
            absolute="$profile_path"
        else
            absolute="$HOME/.mozilla/firefox/$profile_path"
        fi

        [[ -d "$absolute" ]] || continue
        mkdir -p "$absolute/chrome"
        [[ -f "$user_chrome" ]] && cp -f -- "$user_chrome" "$absolute/chrome/userChrome.css"
        [[ -f "$user_content" ]] && cp -f -- "$user_content" "$absolute/chrome/userContent.css"
        [[ -f "$user_js" ]] && cp -f -- "$user_js" "$absolute/user.js"
    done < "$ini"
}


setup_lab_directories() {
    info 'Creating all user-owned lab/workspace directories under home...'
    mkdir -p \
        "$TOOLS_DIR" "$LAB_ROOT" \
        "$HOME/wordlists" "$HOME/vpn" \
        "$HOME/htb/vpn" "$HOME/htb/machines" "$HOME/htb/challenges" "$HOME/htb/academy" "$HOME/htb/notes" "$HOME/htb/loot" "$HOME/htb/tools" \
        "$HOME/hacksmarter/vpn" "$HOME/hacksmarter/labs" "$HOME/hacksmarter/notes" "$HOME/hacksmarter/loot" "$HOME/hacksmarter/tools"
}


safe_home_symlink() {
    local target=$1 link=$2 current=''
    if [[ -L "$link" ]]; then
        current="$(readlink -- "$link" 2>/dev/null || true)"
        if [[ "$current" == "$target" ]]; then
            ln -sfn -- "$target" "$link"
        else
            warn "Leaving existing user symlink untouched: $link -> $current"
            return 0
        fi
    elif [[ -e "$link" ]]; then
        warn "Leaving existing user path untouched instead of replacing it with a symlink: $link"
        return 0
    else
        ln -s -- "$target" "$link"
    fi
}


link_kali_resources_into_home() {
    mkdir -p "$TOOLS_DIR" "$HOME/wordlists"
    [[ -d /usr/share/seclists ]] && safe_home_symlink /usr/share/seclists "$HOME/wordlists/SecLists"
    [[ -d /usr/share/payloadsallthethings ]] && safe_home_symlink /usr/share/payloadsallthethings "$HOME/wordlists/PayloadsAllTheThings"
    [[ -d /usr/share/windows-resources ]] && safe_home_symlink /usr/share/windows-resources "$TOOLS_DIR/windows-resources"
    [[ -d /usr/share/ligolo-ng-common-binaries ]] && safe_home_symlink /usr/share/ligolo-ng-common-binaries "$TOOLS_DIR/ligolo-ng-binaries"
    [[ -d /usr/share/chisel-common-binaries ]] && safe_home_symlink /usr/share/chisel-common-binaries "$TOOLS_DIR/chisel-binaries"
    [[ -d /usr/share/peass ]] && safe_home_symlink /usr/share/peass "$TOOLS_DIR/peass"
}


install_wordlists() {
    info 'Installing Kali wordlists and SecLists...'
    apt_install_required wordlists seclists cupp cewl crunch
    mkdir -p "$HOME/wordlists"

    link_kali_resources_into_home

    if [[ -f /usr/share/wordlists/rockyou.txt.gz ]]; then
        safe_home_symlink /usr/share/wordlists/rockyou.txt.gz "$HOME/wordlists/rockyou.txt.gz"
        if [[ ! -e "$HOME/wordlists/rockyou.txt" ]]; then
            local rockyou_tmp="$HOME/wordlists/.rockyou.txt.tmp.$$"
            info 'Creating an uncompressed per-user RockYou copy...'
            rm -f -- "$rockyou_tmp"
            if gzip -dc /usr/share/wordlists/rockyou.txt.gz > "$rockyou_tmp"; then
                mv -f -- "$rockyou_tmp" "$HOME/wordlists/rockyou.txt"
            else
                rm -f -- "$rockyou_tmp"
                die 'Failed to decompress RockYou.'
            fi
        fi
    elif [[ -f /usr/share/wordlists/rockyou.txt ]]; then
        safe_home_symlink /usr/share/wordlists/rockyou.txt "$HOME/wordlists/rockyou.txt"
    fi
}


install_username_anarchy() {
    local tool_dir="$TOOLS_DIR/username-anarchy"
    info 'Installing username-anarchy under ~/tools with its Ruby runtime...'
    apt_install_required ruby-full

    if [[ -d "$tool_dir/.git" ]]; then
        git -C "$tool_dir" pull --ff-only || warn 'username-anarchy update skipped because the checkout has diverged or the network is unavailable.'
    elif [[ ! -e "$tool_dir" ]]; then
        git clone --depth 1 https://github.com/urbanadventurer/username-anarchy.git "$tool_dir"
    else
        die "$tool_dir exists but is not a git checkout; refusing to overwrite your files."
    fi

    [[ -f "$tool_dir/username-anarchy" ]] || die 'username-anarchy checkout is missing the expected executable.'
    chmod 0755 "$tool_dir/username-anarchy"
    safe_home_symlink "$tool_dir/username-anarchy" "$LOCAL_BIN/username-anarchy" || true
    [[ -x "$tool_dir/username-anarchy" ]] || die 'username-anarchy checkout is not executable.'
    command -v username-anarchy >/dev/null 2>&1 || die 'username-anarchy is not available through ~/.local/bin.'
}


install_bloodhound_cli() {
    local machine archive api_json asset_url digest tmp_dir binary actual
    machine="$(uname -m)"

    case "$machine" in
        x86_64|amd64) archive='bloodhound-cli-linux-amd64.tar.gz' ;;
        aarch64|arm64) archive='bloodhound-cli-linux-arm64.tar.gz' ;;
        *) warn "BloodHound CLI upstream does not publish an automatic build for architecture: $machine"; return 0 ;;
    esac

    tmp_dir="$(mktemp -d)"
    api_json="$tmp_dir/release.json"

    info 'Installing the current official SpecterOps BloodHound CLI to ~/.local/bin...'
    curl --fail --location --retry 3 \
        --header 'Accept: application/vnd.github+json' \
        --header 'X-GitHub-Api-Version: 2022-11-28' \
        --output "$api_json" \
        'https://api.github.com/repos/SpecterOps/bloodhound-cli/releases/latest'

    asset_url="$(jq -r --arg name "$archive" '.assets[] | select(.name == $name) | .browser_download_url' "$api_json" | head -n1)"
    digest="$(jq -r --arg name "$archive" '.assets[] | select(.name == $name) | (.digest // "")' "$api_json" | head -n1)"
    [[ -n "$asset_url" && "$asset_url" != null ]] || { rm -rf -- "$tmp_dir"; die "Latest BloodHound CLI release has no $archive asset."; }

    curl --fail --location --retry 3 --output "$tmp_dir/$archive" "$asset_url"

    if [[ "$digest" == sha256:* ]]; then
        actual="$(sha256sum "$tmp_dir/$archive" | awk '{print $1}')"
        [[ "$actual" == "${digest#sha256:}" ]] || { rm -rf -- "$tmp_dir"; die 'BloodHound CLI SHA-256 verification failed.'; }
    else
        warn 'GitHub release metadata did not expose a SHA-256 digest; relying on HTTPS transport and executable verification.'
    fi

    tar -xzf "$tmp_dir/$archive" -C "$tmp_dir"
    binary="$(find "$tmp_dir" -type f -name bloodhound-cli -print -quit)"
    [[ -n "$binary" ]] || { rm -rf -- "$tmp_dir"; die 'BloodHound CLI archive did not contain the expected binary.'; }

    mkdir -p "$MANAGED_BIN"
    install -m 0755 "$binary" "$MANAGED_BIN/bloodhound-cli"
    rm -rf -- "$tmp_dir"

    "$MANAGED_BIN/bloodhound-cli" help >/dev/null || die 'BloodHound CLI installed but failed its help self-check.'
    safe_home_symlink "$MANAGED_BIN/bloodhound-cli" "$LOCAL_BIN/bloodhound-cli" || true
    ok "BloodHound CLI installed under home: $MANAGED_BIN/bloodhound-cli"
}


install_bloodhound_cli_runtime() {
    info 'Installing rootless Podman support for BloodHound CLI...'
    apt_install_required podman podman-compose docker-compose

    # BloodHound CLI can use Podman only in Docker-compatibility mode. We avoid
    # changing system Docker services or /etc. A user-level socket is safe and
    # reversible; if the session has no user systemd instance, leave it manual.
    if command -v systemctl >/dev/null 2>&1 && systemctl --user show-environment >/dev/null 2>&1; then
        systemctl --user enable --now podman.socket || warn 'Could not enable the user Podman socket; run `systemctl --user enable --now podman.socket` after login.'
    else
        warn 'No active user systemd instance; enable podman.socket after logging into i3 if BloodHound CLI requests it.'
    fi
}


install_user_command_link() {
    local name=$1 target=$2 dest existing_target system_existing target_real
    dest="$LOCAL_BIN/$name"

    [[ "$name" != */* && -n "$name" ]] || { warn "Refusing invalid command name: $name"; return 1; }
    [[ -x "$target" ]] || { warn "Cannot expose '$name'; target is not executable: $target"; return 1; }

    mkdir -p "$LOCAL_BIN"
    target_real="$(readlink -f -- "$target" 2>/dev/null || printf '%s' "$target")"

    if [[ -L "$dest" ]]; then
        existing_target="$(readlink -f -- "$dest" 2>/dev/null || true)"
        if [[ "$existing_target" == "$target_real" ]]; then
            return 0
        fi

        # Only replace links clearly managed by this project. Never replace a
        # user's unrelated ~/.local/bin symlink.
        case "$(readlink -- "$dest" 2>/dev/null || true)" in
            /usr/bin/impacket-*|"$MANAGED_BIN"/*|"$TOOLS_DIR"/*)
                ln -sfn -- "$target" "$dest"
                return 0
                ;;
            *)
                warn "Leaving existing user command untouched: $dest"
                return 0
                ;;
        esac
    elif [[ -e "$dest" ]]; then
        warn "Leaving existing user command untouched: $dest"
        return 0
    fi

    # Do not shadow a different system command (for example ping, net or reg).
    # The corresponding impacket-* command remains globally available instead.
    system_existing="$(PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin command -v -- "$name" 2>/dev/null || true)"
    if [[ -n "$system_existing" ]]; then
        return 0
    fi

    ln -s -- "$target" "$dest"
}


make_managed_python_entrypoint() {
    local name script wrapper
    name=$1
    script=$2
    wrapper="$MANAGED_BIN/$name"
    [[ -f "$script" ]] || return 1
    mkdir -p "$MANAGED_BIN"
    cat > "$wrapper" <<EOF
#!/usr/bin/env bash
exec /usr/bin/python3 $(printf '%q' "$script") "\$@"
EOF
    chmod 0755 "$wrapper"
    printf '%s\n' "$wrapper"
}


install_impacket_shortcuts() {
    local pkg source base short lower prefixed example wrapper resolved
    local -a sources=()
    local manifest="$STATE_DIR/impacket-shortcuts.tsv"

    dpkg-query -W -f='${Status}' impacket-scripts 2>/dev/null | grep -q 'install ok installed' || return 0
    info 'Creating collision-safe short commands for every installed Impacket script...'

    # Prefer Kali's packaged /usr/bin/impacket-* entry points. These remain
    # package-managed and survive Impacket upgrades; ~/.local/bin contains only
    # lightweight convenience symlinks such as wmiexec -> impacket-wmiexec.
    while IFS= read -r source; do
        [[ -x "$source" ]] && sources+=("$source")
    done < <(
        for pkg in impacket-scripts python3-impacket; do
            dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q 'install ok installed' || continue
            dpkg -L "$pkg" 2>/dev/null || true
        done | awk '/^\/usr\/bin\/impacket-/ {print}' | sort -u
    )

    # If Kali has gained a new Impacket example but impacket-scripts has not yet
    # exposed it, create a home-owned prefixed wrapper. This never edits /usr.
    if [[ -d /usr/share/doc/python3-impacket/examples ]]; then
        while IFS= read -r -d '' example; do
            short="$(basename "$example" .py)"
            prefixed="$(command -v -- "impacket-$short" 2>/dev/null || true)"
            if [[ -n "$prefixed" ]]; then
                sources+=("$prefixed")
            else
                wrapper="$(make_managed_python_entrypoint "impacket-$short" "$example")" || continue
                sources+=("$wrapper")
            fi
        done < <(find /usr/share/doc/python3-impacket/examples -maxdepth 1 -type f -name '*.py' -print0 | sort -z)
    fi

    : > "$manifest"
    for source in "${sources[@]}"; do
        base="$(basename "$source")"
        short="${base#impacket-}"
        [[ "$short" != "$base" ]] || continue

        install_user_command_link "$short" "$source"
        resolved="$(command -v -- "$short" 2>/dev/null || true)"
        [[ -n "$resolved" ]] && printf '%s\t%s\n' "$short" "$resolved" >> "$manifest"

        # Also add a lowercase form when it is safe. This makes commands such as
        # GetUserSPNs usable as getuserspns without shadowing existing utilities.
        lower="$(printf '%s' "$short" | tr '[:upper:]' '[:lower:]')"
        if [[ "$lower" != "$short" ]]; then
            install_user_command_link "$lower" "$source"
            resolved="$(command -v -- "$lower" 2>/dev/null || true)"
            [[ -n "$resolved" ]] && printf '%s\t%s\n' "$lower" "$resolved" >> "$manifest"
        fi
    done

    # Common CPTS spelling: Kali intentionally names the binary certipy-ad.
    # Expose certipy too when no unrelated command already owns that name.
    if command -v certipy-ad >/dev/null 2>&1; then
        install_user_command_link certipy "$(command -v certipy-ad)"
    fi

    # These are the high-value aliases we explicitly guarantee for the AD/CPTS
    # profile. The underlying impacket-* names remain available as well.
    for short in wmiexec smbexec psexec secretsdump ntlmrelayx GetUserSPNs GetNPUsers getTGT getST mssqlclient lookupsid rbcd dacledit owneredit atexec dcomexec; do
        if ! command -v -- "$short" >/dev/null 2>&1; then
            prefixed="$(command -v -- "impacket-$short" 2>/dev/null || true)"
            [[ -n "$prefixed" ]] || die "Impacket is installed but required entry point is unavailable: $short"
            install_user_command_link "$short" "$prefixed"
        fi
        command -v -- "$short" >/dev/null 2>&1 || die "Failed to expose Impacket command globally: $short"
    done

    sort -u -o "$manifest" "$manifest" 2>/dev/null || true
    ok 'Impacket short commands are available through ~/.local/bin.'
}


verify_tool_command_surface() {
    local cmd
    local -a required=(
        wmiexec smbexec psexec secretsdump ntlmrelayx GetUserSPNs GetNPUsers getTGT getST
        mssqlclient lookupsid rbcd dacledit owneredit atexec dcomexec
    )

    dpkg-query -W -f='${Status}' impacket-scripts 2>/dev/null | grep -q 'install ok installed' || return 0
    export PATH="$LOCAL_BIN:$MANAGED_BIN:$PATH"

    for cmd in "${required[@]}"; do
        command -v -- "$cmd" >/dev/null 2>&1 || die "Tool command is not reachable through PATH: $cmd"
    done

    # Verify the commands resolve without relying on the current directory.
    ( cd / && command -v wmiexec >/dev/null && command -v smbexec >/dev/null && command -v psexec >/dev/null ) || \
        die 'Impacket shortcuts are not independent of the current working directory.'
    ok 'Global command-surface verification passed.'
}


verify_i3_config() {
    if command -v i3 >/dev/null 2>&1 && [[ -f "$HOME/.config/i3/config" ]]; then
        info 'Validating i3 configuration...'
        i3 -C -c "$HOME/.config/i3/config" >/dev/null || die 'i3 rejected ~/.config/i3/config.'
    fi
}


verify_user_configs() {
    local file tmux_socket="kali-clean-check-$$"

    info 'Validating installed shell and desktop configuration files...'
    for file in "$HOME"/.config/i3/blocks/* "$HOME"/.config/i3/scripts/*.sh; do
        [[ -f "$file" ]] || continue
        bash -n "$file" || die "Bash syntax validation failed: $file"
        [[ -x "$file" ]] || die "Required i3 helper is not executable: $file"
    done
    if [[ -f "$HOME/.fehbg" ]]; then
        sh -n "$HOME/.fehbg" || die 'Wallpaper entry-point syntax validation failed.'
        [[ -x "$HOME/.fehbg" ]] || die 'Wallpaper entry point is not executable: ~/.fehbg'
    fi
    [[ ! -f "$HOME/.zshrc" ]] || zsh -n "$HOME/.zshrc" || die 'zsh rejected ~/.zshrc.'
    [[ ! -f "$HOME/.config/kali-clean/env-sync.zsh" ]] || \
        zsh -n "$HOME/.config/kali-clean/env-sync.zsh" || die 'zsh rejected env-sync.zsh.'

    if [[ -f "$HOME/.config/kali-clean/env-sync.py" ]]; then
        python3 -c 'import pathlib,sys; compile(pathlib.Path(sys.argv[1]).read_text(), sys.argv[1], "exec")' \
            "$HOME/.config/kali-clean/env-sync.py" || die 'Python rejected env-sync.py.'
    fi

    if [[ -f "$HOME/.config/i3/status.py" ]]; then
        python3 -c 'import pathlib,sys; compile(pathlib.Path(sys.argv[1]).read_text(), sys.argv[1], "exec")' \
            "$HOME/.config/i3/status.py" || die 'Python rejected i3/status.py.'
        python3 "$HOME/.config/i3/status.py" --once >/dev/null || die 'i3 status self-check failed.'
    fi

    if [[ -f "$HOME/.config/alacritty/alacritty.toml" ]]; then
        python3 -c 'import sys,tomllib; tomllib.load(open(sys.argv[1], "rb"))' \
            "$HOME/.config/alacritty/alacritty.toml" || die 'Alacritty TOML is invalid.'
    fi

    # Start an isolated throwaway tmux server so tmux itself parses the config.
    if [[ -f "$HOME/.tmux.conf" ]]; then
        if tmux -L "$tmux_socket" -f "$HOME/.tmux.conf" new-session -d -s config-check 'sleep 2'; then
            tmux -L "$tmux_socket" kill-server >/dev/null 2>&1 || true
        else
            tmux -L "$tmux_socket" kill-server >/dev/null 2>&1 || true
            die 'tmux rejected ~/.tmux.conf.'
        fi
    fi
}


verify_apt_health() {
    local audit
    info 'Checking dpkg/APT health...'
    audit="$(sudo dpkg --audit 2>&1)" || die "dpkg audit failed: $audit"
    [[ -z "$audit" ]] || die "dpkg reports unfinished or inconsistent package state:
$audit"
    sudo apt-get check >/dev/null || die 'APT dependency check failed. Repair the package state before continuing.'
    ok 'APT/dpkg health check passed.'
}



preflight_required_packages() {
    local pkg
    local -a missing=()
    info 'Preflighting all required package names against this Kali rolling snapshot...'
    for pkg in "${SYSTEM_PACKAGES[@]}" "${SECURITY_PACKAGES[@]}"; do
        apt_has_package "$pkg" || missing+=("$pkg")
    done
    if grep -Eqi 'vmware' /sys/class/dmi/id/{product_name,sys_vendor} 2>/dev/null; then
        apt_has_package open-vm-tools-desktop || missing+=(open-vm-tools-desktop)
    fi
    ((${#missing[@]} == 0)) || die "Required Kali package(s) have no installable candidate: ${missing[*]}"
    ok 'All required Kali package names have installable candidates.'
}

install_system_packages() {
    info 'Installing the Kali i3 desktop and workstation foundation...'
    apt_install_required "${SYSTEM_PACKAGES[@]}"
    apt_install_available "${QOL_PACKAGES[@]}"

    if grep -Eqi 'vmware' /sys/class/dmi/id/{product_name,sys_vendor} 2>/dev/null; then
        info 'VMware detected; installing guest integration.'
        apt_install_required open-vm-tools-desktop
    fi
}

install_security_tools() {
    info 'Installing the HTB / HackSmarter / CPTS workstation toolset...'
    apt_install_required "${SECURITY_PACKAGES[@]}"
    apt_install_available "${OPTIONAL_SECURITY_PACKAGES[@]}"
}

apply_wallpaper_preference() {
    local selected="$HOME/.wallpaper/$WALLPAPER_CHOICE"
    [[ -f "$selected" ]] || { WALLPAPER_CHOICE='default.png'; selected="$HOME/.wallpaper/default.png"; }
    [[ -f "$selected" ]] || die 'No bundled wallpaper was installed.'
    ln -sfn "$WALLPAPER_CHOICE" "$HOME/.wallpaper/current"
    /usr/bin/env bash "$HOME/.config/i3/scripts/set-wallpaper.sh" --check || die 'Selected wallpaper failed validation.'
    if [[ -n "${DISPLAY:-}" ]]; then
        /usr/bin/env bash "$HOME/.config/i3/scripts/set-wallpaper.sh" >/dev/null 2>&1 || warn 'Could not apply the wallpaper in the current desktop session; i3 will apply it at login.'
    fi
}

install_oh_my_zsh() {
    apt_install_required zsh-autosuggestions zsh-syntax-highlighting
    if [[ -d "$HOME/.oh-my-zsh/.git" ]]; then
        git -C "$HOME/.oh-my-zsh" pull --ff-only || warn 'Oh My Zsh update skipped.'
    elif [[ ! -e "$HOME/.oh-my-zsh" ]]; then
        info 'Installing Oh My Zsh without curl|sh...'
        git clone --depth 1 https://github.com/ohmyzsh/ohmyzsh.git "$HOME/.oh-my-zsh" || warn 'Could not clone Oh My Zsh; the supplied zsh config still works without it.'
    else
        warn "$HOME/.oh-my-zsh exists and is not a git checkout; leaving it untouched."
    fi
}

verify_runtime_surface() {
    local cmd
    local -a required=(
        i3 rofi picom feh flameshot alacritty zsh tmux pipx git curl firefox-esr
        nmap rustscan autorecon ffuf feroxbuster nxc evil-winrm evil-winrm-py certipy-ad
        bloodhound-start bloodhound-ce-python xfreerdp chisel ligolo-proxy penelope
        msfconsole searchsploit smbclient rpcclient podman
    )
    local -a missing=()
    export PATH="$LOCAL_BIN:$MANAGED_BIN:$PATH"
    for cmd in "${required[@]}"; do
        command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
    done
    ((${#missing[@]} == 0)) || die "Installation completed with missing required commands: ${missing[*]}"

    [[ -L "$HOME/.wallpaper/current" ]] || die '~/.wallpaper/current was not created.'
    /usr/bin/env bash "$HOME/.config/i3/scripts/set-wallpaper.sh" --check || die 'Wallpaper runtime check failed.'
    python3 "$HOME/.config/i3/status.py" --once >/dev/null || die 'Top-bar status runtime check failed.'

    # Ensure the terminal command itself is healthy. We do not launch a GUI
    # window during unattended verification.
    alacritty --version >/dev/null || die 'Alacritty executable self-check failed.'

    verify_i3_config
    verify_user_configs
    ok 'Desktop/runtime verification passed.'
}

print_summary() {
    printf '\n%b%bInstallation complete.%b\n\n' "$C_BOLD" "$C_GREEN" "$C_RESET"
    printf 'Log:            %s\n' "$LOG_FILE"
    printf 'Backups:        %s\n' "$BACKUP_ROOT"
    printf 'Wallpaper:      %s\n' "$HOME/.wallpaper/$WALLPAPER_CHOICE"
    printf 'Tools:          %s\n' "$TOOLS_DIR"
    printf 'Labs:           %s\n' "$LAB_ROOT"
    printf 'VPN:            %s\n' "$HOME/vpn"
    printf 'HTB VPN:        %s\n' "$HOME/htb/vpn"
    printf 'HackSmarter VPN:%s\n' " $HOME/hacksmarter/vpn"
    printf 'Wordlists:      %s\n\n' "$HOME/wordlists"
    printf 'Reboot and select the i3 session. Mod+Enter opens the terminal; Mod+Shift+B changes wallpaper.\n'
    printf 'The top-bar VPN address is left-click copyable.\n'
    printf 'Persistent lab vars: export ip=10.10.11.23 ; export ip2=10.10.11.24 ; persistedenv\n'
    printf 'BloodHound is installed but not initialized automatically. When needed: sudo bloodhound-setup\n'
}

main() {
    (($# == 0)) || die 'This installer takes no options. Run exactly: ./install.sh'
    require_normal_user
    require_kali
    choose_wallpaper
    prime_sudo

    apt_refresh
    verify_apt_health
    preflight_required_packages
    install_system_packages
    install_security_tools
    verify_apt_health

    # Everything below is user-owned except the login-shell field changed by chsh.
    setup_lab_directories
    install_wordlists
    install_username_anarchy
    install_bloodhound_cli
    install_bloodhound_cli_runtime
    install_geist_mono
    install_oh_my_zsh

    install_repo_dotfiles
    apply_font_fallback
    apply_wallpaper_preference
    configure_login_shell
    configure_default_browser
    install_firefox_customizations

    install_impacket_shortcuts
    link_kali_resources_into_home
    verify_tool_command_surface
    verify_runtime_surface
    verify_apt_health
    print_summary
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
