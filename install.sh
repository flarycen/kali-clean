#!/usr/bin/env bash
# kali-clean — Kali i3 workstation for HTB / CPTS-style labs and exams.
# Inspired by xct/kali-clean and Pebl3/kali-clean.
#
# Run as your normal user (never root):   ./install.sh
#
# Safety rules this script follows:
#   * APT never removes a package: every transaction is simulated first and
#     run with --no-remove; anything that would remove something is skipped.
#   * Installed packages are not upgraded (--no-upgrade); existing config
#     files are kept (--force-confold).
#   * No system configuration changes (only `chsh` to zsh, if needed), no
#     services, no boot/network changes. Everything else lives in your home
#     directory, and replaced dotfiles are backed up.
#   * Only the desktop basics are mandatory. Every tool is best-effort: a
#     missing package or a failed download is reported, never fatal.
#   * Safe to re-run: existing tools are kept, missing ones are added.

set -Eeuo pipefail
IFS=$'\n\t'
umask 022

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly SCRIPT_DIR
readonly STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/kali-clean"
readonly LOG_FILE="$STATE_DIR/install.log"
readonly ISSUES_FILE="$STATE_DIR/issues.txt"
readonly BACKUP_ROOT="$STATE_DIR/backups"
readonly LOCAL_BIN="$HOME/.local/bin"
readonly KC_SHARE="$HOME/.local/share/kali-clean"
readonly MANAGED_BIN="$KC_SHARE/bin"
readonly TOOLS="$HOME/tools"
readonly WRAPPER_MARK='# kali-clean managed wrapper'
readonly SYSTEM_PATH='/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin'

WALLPAPER_CHOICE='contour.png'
BACKUP_DIR=''
SUDO_KEEPALIVE_PID=''

# ============================================================== packages
# The only hard requirement is an i3 window manager: Kali's i3 desktop, or
# plain i3 when that metapackage cannot be installed without removing anything.
readonly WM_PACKAGE='kali-desktop-i3'
readonly -a WM_FALLBACK_PACKAGES=( i3-wm i3lock )

# What the desktop configuration uses (installed first, best-effort).
readonly -a CORE_PACKAGES=(
    alacritty zsh tmux ncurses-term rofi feh dunst libnotify-bin
    xclip xdotool x11-xserver-utils fonts-jetbrains-mono
    git curl ca-certificates jq unzip python3 file iproute2
)

# Only needed for the Python tools installed into your home (pipx, PKINITtools).
readonly -a PYTHON_TOOLING_PACKAGES=( python3-venv pipx )

# Desktop polish and everyday tools (best-effort).
readonly -a DESKTOP_PACKAGES=(
    papirus-icon-theme flameshot thunar lxpolkit network-manager-gnome unclutter
    xsel pulseaudio-utils playerctl brightnessctl gnome-themes-extra librsvg2-common
    zsh-autosuggestions fzf zoxide bat fd-find ripgrep eza btop htop neovim tree
    pv ncdu shellcheck ansifilter python-is-python3 zip 7zip p7zip-full xxd
    openvpn wireguard-tools network-manager-openvpn network-manager-openvpn-gnome
    bind9-dnsutils whois traceroute net-tools tcpdump faketime ntpsec-ntpdate
    ruby
)

# Kali's own default toolset first; it covers most of what the list below names.
readonly -a KALI_META_PACKAGES=( kali-linux-default )

# HTB / CPTS toolset (best-effort; anything not in your Kali snapshot is reported).
readonly -a SECURITY_PACKAGES=(
    # scanning / footprinting / services
    nmap masscan rustscan naabu autorecon nbtscan ike-scan
    dnsrecon dnsenum fierce sublist3r amass subfinder assetfinder findomain dnsx httpx-toolkit
    whatweb wafw00f nikto eyewitness gowitness nuclei theharvester recon-ng finalrecon
    smtp-user-enum ismtp swaks snmp onesixtyone braa snmpcheck ssh-audit sslscan testssl.sh
    ftp lftp tftp-hpa telnet finger rusers rwho rsh-client nfs-common cifs-utils
    smbclient samba-common-bin smbmap enum4linux enum4linux-ng polenum ridenum
    ldap-utils ldeep python3-ldapdomaindump krb5-user kerberoast ipmitool
    redis-tools default-mysql-client postgresql-client sqlite3 sqsh freetds-bin
    odat oscanner tnscmd10g rdesktop freerdp3-x11 freerdp-x11
    # web
    burpsuite zaproxy ffuf gobuster feroxbuster dirsearch dirb wfuzz sqlmap commix
    xsstrike sstimap wpscan joomscan cmseek arjun katana hakrawler gospider getallurls
    waybackpy phpggc webshells laudanum weevely cewl davtest cadaver
    # passwords
    hashcat hashcat-utils john hashid hash-identifier name-that-hash hydra medusa patator
    crowbar ncrack legba brutespray cupp crunch rsmangler maskprocessor princeprocessor
    wordlists seclists payloadsallthethings bopscrk linkedin2username gpp-decrypt
    lapsdumper dploot hekatomb trufflehog gitleaks creddump7 samdump2 pdfcrack fcrackzip
    # active directory / windows
    impacket-scripts python3-impacket netexec crackmapexec evil-winrm evil-winrm-py
    certipy-ad certi coercer bloodhound bloodhound-ce-python bloodhound.py bloodyad
    krbrelayx mitm6 responder snaffler-ng sprayhound mssqlpwner
    sharphound rubeus mimikatz powersploit nishang powercat windows-binaries
    windows-privesc-check ncat-w32
    # python modules used by the git-based tools in ~/tools
    python3-ldap3 python3-ldap python3-pyasn1 python3-rich python3-pycryptodome
    python3-dnspython python3-six
    # shells / pivoting / file transfer
    netcat-traditional ncat socat rlwrap penelope hoaxshell sshpass proxychains4 sshuttle
    chisel chisel-common-binaries ligolo-ng ligolo-ng-common-binaries
    dnscat2 iodine ptunnel goshs wsgidav python3-pyftpdlib
    # privesc / exploits / misc
    peass pspy linux-exploit-suggester unix-privesc-check
    metasploit-framework exploitdb libimage-exiftool-perl steghide binwalk
    wireshark tshark powershell
)

# ============================================================== output helpers
C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_WHITE=$'\033[97m'

export PATH="$LOCAL_BIN:$MANAGED_BIN:$PATH"
mkdir -p -- "$STATE_DIR" "$BACKUP_ROOT"
: > "$ISSUES_FILE"
exec > >(tee -a "$LOG_FILE") 2>&1

section() { printf '\n%s%s== %s%s\n' "$C_BOLD" "$C_WHITE" "$*" "$C_RESET"; }
info()    { printf '%s[+]%s %s\n' "$C_WHITE" "$C_RESET" "$*"; }
ok()      { printf '%s[✓]%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn()    { printf '%s[!]%s %s\n' "$C_YELLOW" "$C_RESET" "$*"; printf '%s\n' "$*" >> "$ISSUES_FILE"; }
die()     { printf '%s[x]%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; exit 1; }

on_error() {
    local code=$? line=${1:-?}
    printf '%s[x]%s Stopped at install.sh line %s (exit %s). Nothing was removed.\n    Log: %s\n' \
        "$C_RED" "$C_RESET" "$line" "$code" "$LOG_FILE" >&2
    exit "$code"
}
trap 'on_error "$LINENO"' ERR

cleanup() {
    [[ -n "$SUDO_KEEPALIVE_PID" ]] && kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true
}
trap cleanup EXIT

# Run a best-effort step in a subshell: inside it any error stops that step
# (set -e), but the failure is only reported and the install goes on.
optional() {
    local desc=$1 rc
    shift
    trap - ERR
    set +e
    ( set -e; "$@" )
    rc=$?
    set -e
    trap 'on_error "$LINENO"' ERR
    if (( rc != 0 )); then
        warn "$desc did not finish cleanly (exit $rc); see $LOG_FILE"
    fi
    return 0
}

have() { command -v -- "$1" >/dev/null 2>&1; }

# Join arguments with single spaces (IFS is newline/tab in this script).
words() { local IFS=' '; printf '%s' "$*"; }

# ============================================================== preflight
require_normal_user() {
    [[ ${EUID:-$(id -u)} -ne 0 ]] || die 'Run ./install.sh as your normal Kali user, not root (it asks for sudo itself).'
    have sudo || die 'sudo is required.'
}

require_kali() {
    [[ -r /etc/os-release ]] || die 'Cannot identify the operating system.'
    local id='' pretty=''
    id="$(. /etc/os-release && printf '%s' "${ID:-}")"
    pretty="$(. /etc/os-release && printf '%s' "${PRETTY_NAME:-unknown}")"
    [[ "$id" == kali ]] || die "This installer only supports Kali Linux (found: $pretty)."
}

choose_wallpaper() {
    local input=''
    [[ -t 0 ]] || return 0
    cat <<'MENU'

Wallpaper (change any time with Mod+Shift+B)
  1  Contour   dark topographic lines (default)
  2  Black     solid near-black
  3  Dots      faint dot grid
  4  Grid      fine line grid
  5  Grain     subtle film grain
MENU
    read -r -p 'Wallpaper [1]: ' input || input=''
    case "${input:-1}" in
        1) WALLPAPER_CHOICE='contour.png' ;;
        2) WALLPAPER_CHOICE='black.png' ;;
        3) WALLPAPER_CHOICE='dots.png' ;;
        4) WALLPAPER_CHOICE='grid.png' ;;
        5) WALLPAPER_CHOICE='grain.png' ;;
        *) info "Unknown choice '$input'; using Contour." ;;
    esac
}

start_sudo() {
    info 'Asking for sudo once (kept alive while the installer runs)...'
    sudo -v
    ( while kill -0 "$$" 2>/dev/null; do sudo -n -v 2>/dev/null || exit 0; sleep 50; done ) &
    SUDO_KEEPALIVE_PID=$!
}

is_vmware() {
    if have systemd-detect-virt && [[ "$(systemd-detect-virt 2>/dev/null || true)" == vmware ]]; then
        return 0
    fi
    grep -qi vmware /sys/class/dmi/id/sys_vendor /sys/class/dmi/id/product_name 2>/dev/null
}

# ============================================================== apt
APT_REASON=''
APT_LAST_OUT=''
APT_REMOVALS=''
APT_GOOD=()
APT_BLOCKED=()
APT_BROKEN=()
BLOCKED_TOTAL=0
declare -A APT_CANDIDATE=()

# One apt-cache call for many packages; apt_available() then needs no lookup.
apt_load_candidates() {
    local pkg val
    while IFS=$'\t' read -r pkg val; do
        [[ -n "$pkg" ]] && APT_CANDIDATE["$pkg"]="$val"
    done < <(LC_ALL=C apt-cache policy -- "$@" 2>/dev/null \
        | awk '/^[^ ].*:$/ {sub(/:$/, ""); p = $0; next} /^  Candidate:/ {print p "\t" $2}')
    return 0
}

apt_available() {
    local candidate
    if [[ -n "${APT_CANDIDATE[$1]+set}" ]]; then
        candidate="${APT_CANDIDATE[$1]}"
    else
        candidate="$(LC_ALL=C apt-cache policy -- "$1" 2>/dev/null | awk '/Candidate:/ {print $2; exit}')"
    fi
    [[ -n "$candidate" && "$candidate" != "(none)" ]]
}

pkg_installed() {
    dpkg-query -W -f='${Status}' -- "$1" 2>/dev/null | grep -q 'install ok installed'
}

# Print which of the given packages are installed (one dpkg-query call).
installed_of() {
    dpkg-query -W -f='${Package}\t${Status}\n' -- "$@" 2>/dev/null \
        | awk -F'\t' '$2 == "install ok installed" {print $1}'
    return 0
}

# Succeeds only if APT can install the packages without removing anything.
apt_simulate() {
    local out
    APT_REASON=''
    if ! out="$(LC_ALL=C apt-get -s -q install --no-upgrade -- "$@" 2>&1)"; then
        APT_LAST_OUT="$out"
        APT_REASON="$(grep -E '^(E:| )' <<< "$out" | head -n 3 | tr -s ' \n' ' ')"
        APT_REASON="${APT_REASON:-dependency problem}"
        return 1
    fi
    APT_LAST_OUT="$out"
    if grep -q '^Remv ' <<< "$out"; then
        APT_REASON="would remove: $(awk '/^Remv / {print $2}' <<< "$out" | paste -sd ' ' -)"
        return 1
    fi
    return 0
}

apt_do_install() {
    sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y -q --no-upgrade --no-remove \
        -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold -- "$@"
}

# Sort packages into APT_GOOD (installable without removing anything),
# APT_BLOCKED (would remove an installed package) and APT_BROKEN (dependency
# problems). Binary search, so only a few simulations are needed.
apt_partition() {
    (($#)) || return 0
    if apt_simulate "$@"; then
        APT_GOOD+=("$@")
        return 0
    fi
    if (($# == 1)); then
        if [[ "$APT_REASON" == 'would remove: '* ]]; then
            APT_BLOCKED+=("$1")
            APT_REMOVALS+=" ${APT_REASON#would remove: }"
        else
            APT_BROKEN+=("$1")
        fi
        return 0
    fi
    local half=$(( $# / 2 ))
    apt_partition "${@:1:half}"
    apt_partition "${@:half+1}"
}

# Packages from the arguments that are not installed yet but are in the repo.
APT_TODO=()
apt_collect_todo() {
    local label=$1 pkg
    shift
    local -A present=()
    local -a missing=()
    APT_TODO=()
    while IFS= read -r pkg; do
        [[ -n "$pkg" ]] && present["$pkg"]=1
    done < <(installed_of "$@")
    for pkg in "$@"; do
        [[ -n "${present[$pkg]+set}" ]] && continue
        if apt_available "$pkg"; then
            APT_TODO+=("$pkg")
        else
            missing+=("$pkg")
        fi
    done
    if ((${#missing[@]})) && [[ -n "$label" ]]; then
        warn "$label: not in your Kali repositories, skipped: $(words "${missing[@]}")"
    fi
    return 0
}

# apt_install_set LABEL PKG... — install everything that can be installed
# without removing or upgrading what you have; report the rest. Never fatal.
apt_install_set() {
    local label=$1 pkg removals
    shift
    apt_collect_todo "$label" "$@"
    if ((${#APT_TODO[@]} == 0)); then
        ok "$label: already installed"
        return 0
    fi
    local -a todo=("${APT_TODO[@]}")

    info "$label: installing ${#todo[@]} package(s)..."
    if apt_simulate "${todo[@]}" && apt_do_install "${todo[@]}"; then
        ok "$label: done"
        return 0
    fi

    info "$label: not all of them can be installed as-is; checking which can..."
    APT_GOOD=(); APT_BLOCKED=(); APT_BROKEN=(); APT_REMOVALS=''
    apt_partition "${todo[@]}"
    if ((${#APT_BLOCKED[@]})); then
        removals="$(tr ' ' '\n' <<< "$APT_REMOVALS" | sed '/^$/d' | sort -u | tr '\n' ' ')"
        BLOCKED_TOTAL=$(( BLOCKED_TOTAL + ${#APT_BLOCKED[@]} ))
        warn "$label: skipped $(words "${APT_BLOCKED[@]}") (installing would remove: ${removals% })"
    fi
    if ((${#APT_BROKEN[@]})); then
        warn "$label: skipped, dependency problems in the repository: $(words "${APT_BROKEN[@]}")"
    fi
    ((${#APT_GOOD[@]})) || return 0
    if apt_simulate "${APT_GOOD[@]}" && apt_do_install "${APT_GOOD[@]}"; then
        ok "$label: done (some packages skipped, see notes)"
        return 0
    fi
    # Last resort: one at a time, each simulated again first.
    for pkg in "${APT_GOOD[@]}"; do
        pkg_installed "$pkg" && continue
        if apt_simulate "$pkg" && apt_do_install "$pkg"; then
            :
        else
            warn "$label: could not install $pkg (${APT_REASON:-install failed})"
        fi
    done
    return 0
}

# The one hard requirement. Falls back to plain i3 when Kali's i3 desktop
# metapackage cannot be installed without removing something.
install_window_manager() {
    local wm_only="${WM_FALLBACK_PACKAGES[0]}"
    if pkg_installed "$WM_PACKAGE" || pkg_installed "$wm_only"; then
        ok 'Window manager: i3 already installed'
        return 0
    fi
    info "Window manager: installing $WM_PACKAGE..."
    if apt_available "$WM_PACKAGE" && apt_simulate "$WM_PACKAGE" && apt_do_install "$WM_PACKAGE"; then
        ok "Window manager: $WM_PACKAGE"
        return 0
    fi
    [[ "$APT_REASON" == 'would remove: '* ]] && BLOCKED_TOTAL=$(( BLOCKED_TOTAL + 1 ))
    warn "Window manager: $WM_PACKAGE cannot be installed safely (${APT_REASON:-not in your repositories}); trying plain i3 instead"
    if apt_simulate "${WM_FALLBACK_PACKAGES[@]}" && apt_do_install "${WM_FALLBACK_PACKAGES[@]}"; then
        ok 'Window manager: i3'
        return 0
    fi
    if apt_simulate "$wm_only" && apt_do_install "$wm_only"; then
        ok 'Window manager: i3'
        return 0
    fi
    die "i3 cannot be installed without removing other packages (${APT_REASON:-install failed}).
    Nothing was removed. Bring Kali up to date first, then run ./install.sh again:
        sudo apt update && sudo apt full-upgrade -y && sudo reboot"
}

# Kali is a rolling release: if it has not been upgraded for a while, newer
# packages need newer libraries than the installed ones. Explain that before
# anything is installed instead of failing halfway.
preflight_packages() {
    local answer upgrades
    local -a everything=("$WM_PACKAGE" "${CORE_PACKAGES[@]}" "${PYTHON_TOOLING_PACKAGES[@]}" \
        "${DESKTOP_PACKAGES[@]}" "${KALI_META_PACKAGES[@]}" "${SECURITY_PACKAGES[@]}")
    info 'Checking what can be installed...'
    apt_load_candidates "${everything[@]}"
    apt_collect_todo '' "${everything[@]}"
    ((${#APT_TODO[@]})) || return 0
    local -a pool=("${APT_TODO[@]}") broken=() keep=()
    local -A drop=()
    local _ pkg
    # A package with broken dependencies makes APT stop before it reports
    # removals, so drop the ones it names and look again (a few rounds).
    for _ in 1 2 3 4 5; do
        if apt_simulate "${pool[@]}"; then
            ok "All ${#APT_TODO[@]} missing package(s) can be installed"
            return 0
        fi
        [[ "$APT_REASON" == 'would remove: '* ]] && break
        mapfile -t broken < <(grep -oE '^ [^ ]+ :' <<< "$APT_LAST_OUT" | awk '{print $1}' | sed 's/:.*$//')
        ((${#broken[@]})) || return 0
        drop=()
        for pkg in "${broken[@]}"; do drop["$pkg"]=1; done
        keep=()
        for pkg in "${pool[@]}"; do [[ -n "${drop[$pkg]+set}" ]] || keep+=("$pkg"); done
        ((${#keep[@]} < ${#pool[@]})) || return 0
        pool=("${keep[@]}")
        ((${#pool[@]})) || return 0
    done
    [[ "$APT_REASON" == 'would remove: '* ]] || return 0

    upgrades="$(LC_ALL=C apt-get -s -q dist-upgrade 2>/dev/null | grep -c '^Inst ' || true)"
    printf '\n%s[!] Your Kali is behind its repository%s (%s upgrade(s) waiting).\n' "$C_YELLOW" "$C_RESET" "${upgrades:-?}"
    printf '    Some new packages need newer versions of what is installed, so APT would\n'
    printf '    have to remove packages to add them. kali-clean never does that: those\n'
    printf '    packages are skipped and listed at the end. Everything else is installed.\n'
    printf '    To get the complete toolset, stop now (n) and run:\n'
    printf '        %ssudo apt update && sudo apt full-upgrade -y && sudo reboot%s\n' "$C_BOLD" "$C_RESET"
    printf '    then ./install.sh again.\n\n'
    if [[ -t 0 ]]; then
        read -r -p 'Continue now and skip those packages? [Y/n] ' answer || answer=''
        if [[ "$answer" =~ ^[Nn] ]]; then
            info 'Stopped before installing anything.'
            exit 0
        fi
    fi
    return 0
}

apt_health() {
    local audit
    audit="$(sudo dpkg --audit 2>&1 || true)"
    [[ -z "$audit" ]] || die "dpkg reports unfinished package operations. Fix them first (sudo dpkg --configure -a):
$audit"
    sudo apt-get check -q >/dev/null || die 'APT reports broken dependencies. Fix them first (sudo apt --fix-broken install).'
}

install_packages() {
    section 'Packages'
    info 'Refreshing package lists...'
    sudo apt-get update -q || die 'apt-get update failed. Check your network and /etc/apt/sources.list.'
    apt_health
    ok 'APT/dpkg are healthy'
    preflight_packages

    install_window_manager
    apt_install_set 'Desktop core' "${CORE_PACKAGES[@]}"
    apt_install_set 'Python tooling' "${PYTHON_TOOLING_PACKAGES[@]}"
    apt_install_set 'Desktop extras' "${DESKTOP_PACKAGES[@]}"
    if is_vmware; then
        apt_install_set 'VMware integration' open-vm-tools-desktop
    fi
    apt_install_set 'Kali default toolset' "${KALI_META_PACKAGES[@]}"
    apt_install_set 'HTB/CPTS toolset' "${SECURITY_PACKAGES[@]}"
    apt_health
}

# ============================================================== dotfiles
backup_path() {
    local src=$1 rel
    [[ -e "$src" || -L "$src" ]] || return 0
    rel="${src#"$HOME"/}"
    mkdir -p -- "$BACKUP_DIR/$(dirname -- "$rel")"
    cp -a -- "$src" "$BACKUP_DIR/$rel"
}

# i3 -C does not always set an exit code, so also look for ERROR lines.
i3_config_ok() {
    local out
    out="$(i3 -C -c "$1" 2>&1)" || { printf '%s\n' "$out" >&2; return 1; }
    if grep -q 'ERROR' <<< "$out"; then
        printf '%s\n' "$out" >&2
        return 1
    fi
    return 0
}

# tmux_config_ok FILE — load FILE into a private, throwaway tmux server.
tmux_config_ok() {
    local sock="kc-check-$$-$RANDOM" out rc=0
    out="$(tmux -L "$sock" -f /dev/null new-session -d -s check 'sleep 10' \; source-file "$1" 2>&1)" || rc=$?
    tmux -L "$sock" kill-server >/dev/null 2>&1 || true
    ((rc == 0)) || printf '%s\n' "$out" >&2
    return "$rc"
}

# check_configs DIR — validate the configuration files found under DIR
# (the repository before installing, your home directory afterwards).
check_configs() {
    local dir=$1 f
    for f in "$dir"/.config/i3/scripts/*.sh "$dir/.fehbg"; do
        bash -n "$f" || die "Syntax error in $f"
    done
    if have zsh; then
        zsh -n "$dir/.zshrc" || die "zsh rejected $dir/.zshrc"
        zsh -n "$dir/.config/kali-clean/env-sync.zsh" || die "zsh rejected $dir/.config/kali-clean/env-sync.zsh"
    fi
    for f in "$dir/.config/i3/status.py" "$dir/.config/i3/scripts/vm-autofit.py" \
             "$dir/.config/kali-clean/kcinfo.py" "$dir/.config/kali-clean/env-sync.py"; do
        python3 -c 'import ast,sys; ast.parse(open(sys.argv[1]).read(), sys.argv[1])' "$f" || die "Python rejected $f"
    done
    python3 - "$dir/.config/alacritty/alacritty.toml" <<'PY' || die "$dir/.config/alacritty/alacritty.toml is not valid TOML"
import sys
try:
    import tomllib
except ImportError:  # Python < 3.11: nothing to check with
    sys.exit(0)
with open(sys.argv[1], "rb") as fh:
    tomllib.load(fh)
PY
    if have i3; then
        i3_config_ok "$dir/.config/i3/config" || die "i3 rejected $dir/.config/i3/config"
    fi
    if have tmux; then
        tmux_config_ok "$dir/.tmux.conf" || die "tmux rejected $dir/.tmux.conf"
    fi
    return 0
}

validate_shipped_configs() {
    info 'Validating the new configuration before installing it...'
    check_configs "$SCRIPT_DIR"
    python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$SCRIPT_DIR/.config/firefox/foxyproxy.json" \
        || die 'foxyproxy.json is not valid JSON'
    ok 'Configuration is valid'
}

install_dotfiles() {
    section 'Desktop configuration'
    local name src dst
    BACKUP_DIR="$BACKUP_ROOT/$(date '+%Y%m%d-%H%M%S')"
    mkdir -p -- "$BACKUP_DIR" "$HOME/.config"
    validate_shipped_configs

    # Whole directories owned by this project.
    for name in i3 alacritty rofi dunst; do
        src="$SCRIPT_DIR/.config/$name"
        dst="$HOME/.config/$name"
        [[ -d "$src" ]] || continue
        backup_path "$dst"
        rm -rf -- "$dst"
        cp -a -- "$src" "$dst"
    done

    # kali-clean helpers; session.env (your persisted variables) is kept.
    mkdir -p -- "$HOME/.config/kali-clean"
    for name in env-sync.py env-sync.zsh kcinfo.py; do
        backup_path "$HOME/.config/kali-clean/$name"
        install -m 0644 -- "$SCRIPT_DIR/.config/kali-clean/$name" "$HOME/.config/kali-clean/$name"
    done
    chmod 0755 "$HOME/.config/kali-clean/env-sync.py" "$HOME/.config/kali-clean/kcinfo.py"
    # Leftovers of the old theme switcher.
    for name in themes current theme apply-theme.sh theme-menu.sh; do
        dst="$HOME/.config/kali-clean/$name"
        [[ -e "$dst" || -L "$dst" ]] || continue
        backup_path "$dst"
        rm -rf -- "$dst"
    done

    for name in .zshrc .tmux.conf .fehbg; do
        backup_path "$HOME/$name"
        cp -f -- "$SCRIPT_DIR/$name" "$HOME/$name"
    done

    # GTK: settings.ini + gtk.css only (bookmarks and anything else in gtk-3.0 stay).
    mkdir -p -- "$HOME/.config/gtk-3.0"
    for name in settings.ini gtk.css; do
        backup_path "$HOME/.config/gtk-3.0/$name"
        install -m 0644 -- "$SCRIPT_DIR/.config/gtk-3.0/$name" "$HOME/.config/gtk-3.0/$name"
    done

    # Flameshot: screenshots go to ~/Pictures/Screenshots with a timestamp name.
    mkdir -p -- "$HOME/.config/flameshot" "$HOME/Pictures/Screenshots"
    backup_path "$HOME/.config/flameshot/flameshot.ini"
    sed "s|@HOME@|$HOME|g" "$SCRIPT_DIR/.config/flameshot/flameshot.ini" > "$HOME/.config/flameshot/flameshot.ini"

    # Wallpapers: only the shipped files are managed; your own images stay.
    mkdir -p -- "$HOME/.wallpaper"
    for name in contour.png black.png dots.png grid.png grain.png; do
        install -m 0644 -- "$SCRIPT_DIR/.wallpaper/$name" "$HOME/.wallpaper/$name"
    done

    chmod 0755 "$HOME/.fehbg" "$HOME"/.config/i3/scripts/*.sh "$HOME/.config/i3/scripts/vm-autofit.py" \
        "$HOME/.config/i3/status.py"
    ok "Dotfiles installed (previous versions backed up to $BACKUP_DIR)"
}

apply_wallpaper() {
    [[ -f "$HOME/.wallpaper/$WALLPAPER_CHOICE" ]] || WALLPAPER_CHOICE='contour.png'
    ln -sfn -- "$WALLPAPER_CHOICE" "$HOME/.wallpaper/current"
    if [[ -n "${DISPLAY:-}" ]]; then
        bash "$HOME/.config/i3/scripts/set-wallpaper.sh" >/dev/null 2>&1 || true
    fi
    ok "Wallpaper: $WALLPAPER_CHOICE"
}

install_tmux_plugins() {
    local repo name dest
    mkdir -p -- "$HOME/.tmux/plugins" "$HOME/logs/tmux"
    for repo in tmux-plugins/tmux-logging tmux-plugins/tmux-resurrect; do
        name="${repo#*/}"
        dest="$HOME/.tmux/plugins/$name"
        git_get "$dest" "https://github.com/$repo.git" || warn "tmux plugin $name could not be downloaded"
    done
    ok 'tmux plugins: logging + resurrect'
}

configure_login_shell() {
    local zsh_path
    zsh_path="$(command -v zsh 2>/dev/null || true)"
    if [[ -z "$zsh_path" ]]; then
        warn 'zsh is not installed (see the APT notes); login shell unchanged'
        return 0
    fi
    if [[ "$(getent passwd "$USER" | cut -d: -f7)" != "$zsh_path" ]]; then
        grep -Fxq "$zsh_path" /etc/shells || { warn "$zsh_path is not in /etc/shells; login shell unchanged"; return 0; }
        info "Setting zsh as the login shell for $USER..."
        sudo chsh -s "$zsh_path" "$USER"
    fi
    ok 'Login shell: zsh'
}

# ============================================================== firefox
firefox_bin() {
    local b
    for b in firefox-esr firefox; do
        have "$b" && { printf '%s' "$b"; return 0; }
    done
    return 1
}

# Where Firefox keeps profiles.ini. Since Firefox 147 (and Kali's ESR 153) a
# new profile lives in $XDG_CONFIG_HOME/mozilla/firefox (~/.config/...);
# older versions, or systems that already have ~/.mozilla/firefox, use that.
firefox_roots() {
    local xdg="${XDG_CONFIG_HOME:-}"
    # Firefox ignores a relative or empty XDG_CONFIG_HOME, so do the same.
    [[ "$xdg" == /* ]] || xdg="$HOME/.config"
    printf '%s\n' "$HOME/.mozilla/firefox" "$xdg/mozilla/firefox"
}

# Every profile directory listed in any profiles.ini (relative paths are
# relative to the folder that holds that profiles.ini). Printed once each.
firefox_profiles() {
    local root line path
    local -A seen=()
    while IFS= read -r root; do
        [[ -f "$root/profiles.ini" ]] || continue
        while IFS= read -r line || [[ -n "$line" ]]; do
            line="${line%$'\r'}"
            [[ $line == Path=* ]] || continue
            path="${line#Path=}"
            [[ "$path" == /* ]] || path="$root/$path"
            [[ -d "$path" ]] || continue
            path="$(cd -- "$path" && pwd -P)"
            [[ -n "${seen[$path]+set}" ]] && continue
            seen["$path"]=1
            printf '%s\n' "$path"
        done < "$root/profiles.ini"
    done < <(firefox_roots)
    return 0
}

firefox_roots_text() {
    local root out=''
    while IFS= read -r root; do
        out+="${out:+ or }${root/#$HOME/\~}"
    done < <(firefox_roots)
    printf '%s' "$out"
}

ensure_firefox_profile() {
    local bin tmp
    [[ -n "$(firefox_profiles)" ]] && return 0
    bin="$(firefox_bin)" || return 1
    # A running Firefox without a profile we can see: do not start another one.
    pgrep -u "$USER" -f '(^|/)firefox(-esr)?( |$)' >/dev/null 2>&1 && return 1
    info 'Creating a Firefox profile (one headless start)...'
    tmp="$(mktemp -d)"
    timeout 90 "$bin" --headless --screenshot "$tmp/blank.png" about:blank >/dev/null 2>&1 || true
    rm -rf -- "$tmp"
    [[ -n "$(firefox_profiles)" ]]
}

# Replace only the kali-clean block of an existing user.js.
merge_user_js() {
    local target=$1 tmp
    tmp="$(mktemp)"
    if [[ -f "$target" ]]; then
        awk '/^\/\/ >>> kali-clean/ {skip=1} !skip {print} /^\/\/ <<< kali-clean/ {skip=0}' "$target" > "$tmp"
    fi
    {
        printf '// >>> kali-clean (managed block, re-written by install.sh)\n'
        cat "$SCRIPT_DIR/.config/firefox/user.js"
        printf '// <<< kali-clean\n'
    } >> "$tmp"
    install -m 0644 -- "$tmp" "$target"
    rm -f -- "$tmp"
}

xpi_id() {
    unzip -p "$1" manifest.json 2>/dev/null | python3 -c '
import json, re, sys
raw = sys.stdin.read()
try:
    m = json.loads(raw)
    s = m.get("browser_specific_settings") or m.get("applications") or {}
    print(s.get("gecko", {}).get("id", ""))
except ValueError:
    hit = re.search(r"\"gecko\"\s*:\s*\{[^}]*\"id\"\s*:\s*\"([^\"]+)\"", raw)
    print(hit.group(1) if hit else "")
'
}

# FoxyProxy presets (Burp :8080, SOCKS5 :9050 and :1080) as normal, editable
# settings. The first time an add-on starts in a profile, Firefox imports
# <profile>/browser-extension-data/<id>/storage.js into its storage (the legacy
# storage.local migration in ExtensionStorageIDB.sys.mjs). A profile where
# FoxyProxy already started keeps its own settings.
seed_foxyproxy() {
    local profile=$1 id='foxyproxy@eric.h.jung' dir
    dir="$profile/browser-extension-data/$id"
    grep -qF "\"extensions.webextensions.ExtensionStorageIDB.migrated.$id\", true" \
        "$profile/prefs.js" 2>/dev/null && return 0
    [[ -e "$dir/storage.js" || -e "$dir/storage.js.migrated" ]] && return 0
    mkdir -p -- "$dir"
    install -m 0600 -- "$SCRIPT_DIR/.config/firefox/foxyproxy.json" "$dir/storage.js"
}

# Older kali-clean versions shipped the presets as *managed* storage, which
# FoxyProxy treats as an administrator lock: the mode could not be changed
# from "disable". Remove that file when it is ours.
remove_foxyproxy_lock() {
    local f="$HOME/.mozilla/managed-storage/foxyproxy@eric.h.jung.json"
    [[ -f "$f" ]] && grep -qF 'kali-clean FoxyProxy presets' "$f" || return 0
    rm -f -- "$f"
    rmdir -- "$HOME/.mozilla/managed-storage" 2>/dev/null || true
    rmdir -- "$HOME/.mozilla" 2>/dev/null || true
    info 'FoxyProxy: removed the old kali-clean lock; restart Firefox once'
}

# foxyproxy_lacks_site_access PROFILE: true when Firefox has FoxyProxy
# installed without "Access your data for all websites". It needs that to
# route traffic, and Firefox grants it automatically only to add-ons that
# start as fresh installs (see extensions.startupScanScopes in user.js).
foxyproxy_lacks_site_access() {
    python3 - "$1" <<'PY'
import json, os, sys
profile, addon = sys.argv[1], 'foxyproxy@eric.h.jung'

def load(name):
    try:
        with open(os.path.join(profile, name), encoding='utf-8') as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return None

db = load('extensions.json') or {}
if not any(a.get('id') == addon and a.get('active') for a in db.get('addons') or []):
    sys.exit(1)     # not installed in this profile (yet)
granted = ((load('extension-preferences.json') or {}).get(addon) or {}).get('origins') or []
sys.exit(0 if '<all_urls>' not in granted else 1)
PY
}

install_firefox() {
    section 'Firefox'
    local profile slug tmp id
    local -a profiles=() xpis=()
    if ! ensure_firefox_profile; then
        warn "Firefox: no profile found in $(firefox_roots_text). Open Firefox once, close it, then re-run ./install.sh."
        return 0
    fi
    mapfile -t profiles < <(firefox_profiles)
    ((${#profiles[@]})) || { warn 'No Firefox profile directory found.'; return 0; }

    # Add-ons from addons.mozilla.org (signed): FoxyProxy, Wappalyzer, Cookie-Editor.
    tmp="$(mktemp -d)"
    for slug in foxyproxy-standard wappalyzer cookie-editor; do
        if curl -fsSL --retry 3 --connect-timeout 20 -o "$tmp/$slug.xpi" \
            "https://addons.mozilla.org/firefox/downloads/latest/$slug/latest.xpi"; then
            id="$(xpi_id "$tmp/$slug.xpi")"
            if [[ -n "$id" ]]; then
                mv -- "$tmp/$slug.xpi" "$tmp/$id.xpi"
                xpis+=("$tmp/$id.xpi")
            else
                warn "Firefox add-on $slug: could not read its id"
            fi
        else
            warn "Firefox add-on $slug: download failed"
        fi
    done

    for profile in "${profiles[@]}"; do
        mkdir -p -- "$profile/chrome" "$profile/extensions"
        backup_path "$profile/chrome/userChrome.css"
        backup_path "$profile/chrome/userContent.css"
        cp -f -- "$SCRIPT_DIR/.config/firefox/userChrome.css" "$profile/chrome/userChrome.css"
        cp -f -- "$SCRIPT_DIR/.config/firefox/userContent.css" "$profile/chrome/userContent.css"
        rm -f -- "$profile/chrome/kali-clean-theme.css"
        merge_user_js "$profile/user.js"
        for id in "${xpis[@]}"; do
            [[ -f "$profile/extensions/${id##*/}" ]] || cp -f -- "$id" "$profile/extensions/"
        done
        seed_foxyproxy "$profile"
    done
    rm -rf -- "$tmp"
    remove_foxyproxy_lock

    ok "Firefox styled (${#profiles[@]} profile(s)); add-ons load at next start"
    for profile in "${profiles[@]}"; do
        if foxyproxy_lacks_site_access "$profile"; then
            warn "FoxyProxy cannot route traffic in ${profile/#$HOME/\~} until you allow it once: about:addons > FoxyProxy > Permissions > turn on \"Access your data for all websites\""
        fi
    done
}

# ============================================================== tool helpers
git_get() {
    local dest=$1 url=$2
    if [[ -d "$dest/.git" ]]; then
        GIT_TERMINAL_PROMPT=0 timeout 300 git -C "$dest" pull -q --ff-only >/dev/null 2>&1 || true
        return 0
    fi
    if [[ -e "$dest" ]]; then
        warn "$dest exists and is not a git checkout; left untouched"
        return 0
    fi
    mkdir -p -- "$(dirname -- "$dest")"
    GIT_TERMINAL_PROMPT=0 timeout 900 git clone -q --depth 1 -- "$url" "$dest"
}

# A file in ~/.local/bin that kali-clean created earlier and may replace.
is_managed_command() {
    local path=$1 link
    if [[ -L "$path" ]]; then
        link="$(readlink -- "$path" 2>/dev/null || true)"
        case "$link" in
            /usr/bin/impacket-*|"$MANAGED_BIN"/*|"$TOOLS"/*|"$KC_SHARE"/*) return 0 ;;
        esac
        return 1
    fi
    [[ -f "$path" ]] && head -n 3 -- "$path" 2>/dev/null \
        | grep -qE "^(${WRAPPER_MARK}|# kali-clean managed \.py entry point|# made by add-py-names\.sh)\$"
}

# wrap NAME INTERPRETER TARGET — ~/.local/bin/NAME runs TARGET (with INTERPRETER, if given).
# Never replaces your own files and never hides a command the system already has.
wrap() {
    local name=$1 interp=$2 target=$3 dest existing
    dest="$LOCAL_BIN/$name"
    [[ -n "$name" && "$name" != */* ]] || return 1
    [[ -e "$target" ]] || return 1
    existing="$(PATH="$SYSTEM_PATH" command -v -- "$name" 2>/dev/null || true)"
    if [[ -n "$existing" && "$existing" != "$dest" ]]; then
        return 0
    fi
    if [[ -e "$dest" || -L "$dest" ]]; then
        if is_managed_command "$dest"; then
            rm -f -- "$dest"
        else
            return 0
        fi
    fi
    mkdir -p -- "$LOCAL_BIN"
    {
        printf '#!/usr/bin/env bash\n%s\n' "$WRAPPER_MARK"
        if [[ -n "$interp" ]]; then
            printf 'exec %q %q "$@"\n' "$interp" "$target"
        else
            printf 'exec %q "$@"\n' "$target"
        fi
    } > "$dest"
    chmod 0755 "$dest"
}

# alias_cmd NAME TARGET_COMMAND — NAME runs an existing command.
alias_cmd() {
    local path
    path="$(PATH="$LOCAL_BIN:$SYSTEM_PATH" command -v -- "$2" 2>/dev/null || true)"
    [[ -n "$path" && "$path" != "$LOCAL_BIN/$1" ]] || return 0
    wrap "$1" '' "$path" || true
}

safe_link() {
    local target=$1 link=$2 current
    [[ -e "$target" ]] || return 0
    mkdir -p -- "$(dirname -- "$link")"
    if [[ -L "$link" ]]; then
        current="$(readlink -- "$link" 2>/dev/null || true)"
        [[ "$current" == "$target" ]] && return 0
        case "$current" in
            /usr/share/*) ln -sfn -- "$target" "$link" ;;
        esac
        return 0
    fi
    [[ -e "$link" ]] && return 0
    ln -s -- "$target" "$link"
}

gh_release() {
    # gh_release OWNER/REPO REGEX DEST_DIR — download matching assets of the latest release.
    local repo=$1 regex=$2 dest=$3 json name url digest tmp actual got=0
    local -a auth=()
    [[ -n "${GITHUB_TOKEN:-}" ]] && auth=(-H "Authorization: Bearer $GITHUB_TOKEN")
    json="$(curl -fsSL --retry 3 --connect-timeout 20 -H 'Accept: application/vnd.github+json' "${auth[@]}" \
        "https://api.github.com/repos/$repo/releases/latest" 2>/dev/null)" || {
        warn "GitHub: no release info for $repo (offline or rate-limited; set GITHUB_TOKEN and re-run)"
        return 0
    }
    mkdir -p -- "$dest"
    while IFS=$'\t' read -r name url digest; do
        [[ -n "$name" && -n "$url" ]] || continue
        if [[ -s "$dest/$name" ]]; then
            got=1
            continue
        fi
        tmp="$(mktemp)"
        if curl -fsSL --retry 3 --connect-timeout 20 -o "$tmp" "$url" 2>/dev/null; then
            if [[ "$digest" == sha256:* ]]; then
                actual="$(sha256sum "$tmp" | awk '{print $1}')"
                if [[ "$actual" != "${digest#sha256:}" ]]; then
                    rm -f -- "$tmp"
                    warn "GitHub: checksum mismatch for $repo/$name; discarded"
                    continue
                fi
            fi
            install -m 0644 -- "$tmp" "$dest/$name"
            got=1
        else
            warn "GitHub: download failed for $repo/$name"
        fi
        rm -f -- "$tmp"
    done < <(jq -r --arg re "$regex" '.assets[]? | select(.name | test($re)) | [.name, .browser_download_url, (.digest // "")] | @tsv' <<< "$json")
    ((got)) || warn "GitHub: no asset of $repo matched /$regex/"
    return 0
}

pipx_get() {
    # pipx_get PACKAGE_NAME SPEC [INJECT...]
    local pkg=$1 spec=$2
    shift 2
    have pipx || return 1
    if pipx list --short 2>/dev/null | awk '{print $1}' | grep -qx -- "$pkg"; then
        return 0
    fi
    timeout 900 pipx install --quiet "$spec" >/dev/null 2>&1 || { warn "pipx: could not install $pkg"; return 0; }
    if (($#)); then
        pipx inject --quiet "$pkg" "$@" >/dev/null 2>&1 || warn "pipx: could not add $(words "$@") to $pkg"
    fi
}

# ============================================================== tools
setup_directories() {
    mkdir -p -- "$TOOLS"/{windows,linux,pivot,ad,web,passwords,venvs} "$HOME/wordlists" "$HOME/vpn" \
        "$HOME/labs" "$HOME/logs/tmux" "$HOME/Pictures/Screenshots" \
        "$HOME/htb"/{vpn,machines,challenges,academy,notes,loot,screenshots,tools} \
        "$HOME/hacksmarter"/{vpn,labs,notes,loot,screenshots,tools} \
        "$LOCAL_BIN" "$MANAGED_BIN"
}

install_wordlists() {
    local tmp
    safe_link /usr/share/seclists "$HOME/wordlists/SecLists"
    safe_link /usr/share/payloadsallthethings "$HOME/wordlists/PayloadsAllTheThings"
    safe_link /usr/share/wordlists "$HOME/wordlists/kali"
    if [[ ! -e "$HOME/wordlists/rockyou.txt" ]]; then
        if [[ -f /usr/share/wordlists/rockyou.txt.gz ]]; then
            info 'Unpacking rockyou.txt into ~/wordlists...'
            tmp="$HOME/wordlists/.rockyou.$$"
            gzip -dc /usr/share/wordlists/rockyou.txt.gz > "$tmp" && mv -f -- "$tmp" "$HOME/wordlists/rockyou.txt"
        elif [[ -f /usr/share/wordlists/rockyou.txt ]]; then
            safe_link /usr/share/wordlists/rockyou.txt "$HOME/wordlists/rockyou.txt"
        fi
    fi
    ok 'Wordlists: ~/wordlists (rockyou, SecLists, PayloadsAllTheThings)'
}

# Every Impacket example as NAME, NAME.py and lowercase name (secretsdump,
# secretsdump.py, getuserspns ...). Wrappers call Kali's /usr/bin/impacket-*.
install_impacket_names() {
    local src base short lower
    local -a launchers=()
    mapfile -t launchers < <(find /usr/bin -maxdepth 1 -name 'impacket-*' -perm -u+x 2>/dev/null | sort)
    ((${#launchers[@]})) || { warn 'Impacket launchers not found (/usr/bin/impacket-*)'; return 0; }
    for src in "${launchers[@]}"; do
        base="${src##*/}"
        short="${base#impacket-}"
        [[ -n "$short" && "$short" != "$base" ]] || continue
        wrap "$short" '' "$src" || true
        wrap "$short.py" '' "$src" || true
        lower="${short,,}"
        [[ "$lower" == "$short" ]] || wrap "$lower" '' "$src" || true
    done
    ok "Impacket: ${#launchers[@]} tools as name, name.py and lowercase"
}

# John the Ripper ships ssh2john, office2john, ... as commands; HTB Academy
# calls them ssh2john.py, office2john.py, pdf2john.pl. Add those spellings,
# using the extension of the script each command really runs.
install_john_names() {
    local f name real kind
    for f in /usr/share/john/*2john*.py /usr/share/john/*2john*.pl; do
        [[ -f "$f" ]] || continue
        name="${f##*/}"
        case "$name" in
            *.py) wrap "$name" /usr/bin/python3 "$f" || true ;;
            *.pl) wrap "$name" /usr/bin/perl "$f" || true ;;
        esac
    done
    for f in /usr/bin/*2john; do
        [[ -x "$f" ]] || continue
        name="${f##*/}"
        real="$(readlink -f -- "$f" 2>/dev/null || printf '%s' "$f")"
        case "$real" in
            *.py) kind=py ;;
            *.pl) kind=pl ;;
            *)
                kind=''
                if head -c 200 -- "$real" 2>/dev/null | head -n 1 | grep -q python; then
                    kind=py
                elif head -c 200 -- "$real" 2>/dev/null | head -n 1 | grep -q perl; then
                    kind=pl
                fi
                ;;
        esac
        [[ -n "$kind" ]] && { wrap "$name.$kind" '' "$f" || true; }
    done
    return 0
}

install_command_names() {
    install_john_names
    alias_cmd Responder.py responder
    alias_cmd RunFinger.py responder-RunFinger
    alias_cmd MultiRelay.py responder-MultiRelay
    alias_cmd krbrelayx.py krbrelayx
    alias_cmd addspn.py addspn
    alias_cmd dnstool.py dnstool
    alias_cmd printerbug.py printerbug
    alias_cmd certipy certipy-ad
    alias_cmd bloodyAD bloodyad
    alias_cmd bloodyAD.py bloodyad
    alias_cmd evil-winrm.py evil-winrm-py
    alias_cmd enum4linux-ng.py enum4linux-ng
    alias_cmd odat.py odat
    alias_cmd pywhisker.py pywhisker
    if have crackmapexec; then
        alias_cmd cme crackmapexec
    else
        alias_cmd crackmapexec nxc
        alias_cmd cme nxc
    fi
    ok 'Tool names: *2john.py/.pl, Responder.py, krbrelayx.py, certipy, cme, evil-winrm.py, ...'
}

install_git_tools() {
    local d
    info 'Fetching GitHub tools into ~/tools (shallow clones)...'
    # Active Directory (attacker side)
    git_get "$TOOLS/ad/targetedKerberoast" https://github.com/ShutdownRepo/targetedKerberoast.git || warn 'targetedKerberoast clone failed'
    git_get "$TOOLS/ad/PKINITtools" https://github.com/dirkjanm/PKINITtools.git || warn 'PKINITtools clone failed'
    git_get "$TOOLS/ad/gMSADumper" https://github.com/micahvandeusen/gMSADumper.git || warn 'gMSADumper clone failed'
    git_get "$TOOLS/ad/PetitPotam" https://github.com/topotam/PetitPotam.git || warn 'PetitPotam clone failed'
    git_get "$TOOLS/ad/noPac" https://github.com/Ridter/noPac.git || warn 'noPac clone failed'
    git_get "$TOOLS/ad/CVE-2021-1675" https://github.com/cube0x0/CVE-2021-1675.git || warn 'CVE-2021-1675 clone failed'
    git_get "$TOOLS/ad/windapsearch" https://github.com/ropnop/windapsearch.git || warn 'windapsearch clone failed'
    # Passwords / web
    git_get "$TOOLS/passwords/username-anarchy" https://github.com/urbanadventurer/username-anarchy.git || warn 'username-anarchy clone failed'
    git_get "$TOOLS/passwords/firefox_decrypt" https://github.com/unode/firefox_decrypt.git || warn 'firefox_decrypt clone failed'
    git_get "$TOOLS/passwords/mimipenguin" https://github.com/huntergregal/mimipenguin.git || warn 'mimipenguin clone failed'
    git_get "$TOOLS/web/XXEinjector" https://github.com/enjoiz/XXEinjector.git || warn 'XXEinjector clone failed'
    # Linux targets
    git_get "$TOOLS/linux/LinEnum" https://github.com/rebootuser/LinEnum.git || warn 'LinEnum clone failed'
    git_get "$TOOLS/linux/linux-smart-enumeration" https://github.com/diego-treitos/linux-smart-enumeration.git || warn 'lse clone failed'
    git_get "$TOOLS/linux/linux-exploit-suggester" https://github.com/The-Z-Labs/linux-exploit-suggester.git || warn 'les clone failed'
    git_get "$TOOLS/linux/static-binaries" https://github.com/andrew-d/static-binaries.git || warn 'static-binaries clone failed'
    # Windows targets
    git_get "$TOOLS/windows/SharpCollection" https://github.com/Flangvik/SharpCollection.git || warn 'SharpCollection clone failed'
    git_get "$TOOLS/windows/nc" https://github.com/int0x33/nc.exe.git || warn 'nc.exe clone failed'
    git_get "$TOOLS/windows/Inveigh" https://github.com/Kevin-Robertson/Inveigh.git || warn 'Inveigh clone failed'
    git_get "$TOOLS/windows/DomainPasswordSpray" https://github.com/dafthack/DomainPasswordSpray.git || warn 'DomainPasswordSpray clone failed'
    git_get "$TOOLS/windows/LAPSToolkit" https://github.com/leoloobeek/LAPSToolkit.git || warn 'LAPSToolkit clone failed'
    git_get "$TOOLS/windows/PowerUpSQL" https://github.com/NetSPI/PowerUpSQL.git || warn 'PowerUpSQL clone failed'
    git_get "$TOOLS/windows/Invoke-TheHash" https://github.com/Kevin-Robertson/Invoke-TheHash.git || warn 'Invoke-TheHash clone failed'
    git_get "$TOOLS/windows/JAWS" https://github.com/411Hall/JAWS.git || warn 'JAWS clone failed'
    git_get "$TOOLS/windows/SessionGopher" https://github.com/Arvanaghi/SessionGopher.git || warn 'SessionGopher clone failed'
    git_get "$TOOLS/windows/ADRecon" https://github.com/adrecon/ADRecon.git || warn 'ADRecon clone failed'
    git_get "$TOOLS/windows/Invoke-DOSfuscation" https://github.com/danielbohannon/Invoke-DOSfuscation.git || warn 'Invoke-DOSfuscation clone failed'
    # Pivoting
    git_get "$TOOLS/pivot/rpivot" https://github.com/klsecservices/rpivot.git || warn 'rpivot clone failed'
    git_get "$TOOLS/pivot/ptunnel-ng" https://github.com/utoni/ptunnel-ng.git || warn 'ptunnel-ng clone failed'
    git_get "$TOOLS/pivot/dnscat2-powershell" https://github.com/lukebaggett/dnscat2-powershell.git || warn 'dnscat2-powershell clone failed'

    # Commands for the attacker-side scripts (Kali's python3 modules provide their imports).
    d="$TOOLS/ad"
    wrap targetedKerberoast.py /usr/bin/python3 "$d/targetedKerberoast/targetedKerberoast.py" || true
    wrap gMSADumper.py /usr/bin/python3 "$d/gMSADumper/gMSADumper.py" || true
    wrap PetitPotam.py /usr/bin/python3 "$d/PetitPotam/PetitPotam.py" || true
    wrap noPac.py /usr/bin/python3 "$d/noPac/noPac.py" || true
    wrap noPac-scanner.py /usr/bin/python3 "$d/noPac/scanner.py" || true
    wrap CVE-2021-1675.py /usr/bin/python3 "$d/CVE-2021-1675/CVE-2021-1675.py" || true
    wrap printnightmare.py /usr/bin/python3 "$d/CVE-2021-1675/CVE-2021-1675.py" || true
    wrap windapsearch.py /usr/bin/python3 "$d/windapsearch/windapsearch.py" || true
    wrap username-anarchy /usr/bin/ruby "$TOOLS/passwords/username-anarchy/username-anarchy" || true
    wrap firefox_decrypt.py /usr/bin/python3 "$TOOLS/passwords/firefox_decrypt/firefox_decrypt.py" || true
    wrap firefox_decrypt /usr/bin/python3 "$TOOLS/passwords/firefox_decrypt/firefox_decrypt.py" || true
    wrap XXEinjector.rb /usr/bin/ruby "$TOOLS/web/XXEinjector/XXEinjector.rb" || true
    wrap xxeinjector /usr/bin/ruby "$TOOLS/web/XXEinjector/XXEinjector.rb" || true
    ok 'GitHub tools ready in ~/tools'
}

# PKINITtools needs minikerberos + an OpenSSL-3-compatible oscrypto: own venv.
install_pkinittools() {
    local venv="$TOOLS/venvs/pkinittools" src="$TOOLS/ad/PKINITtools" f
    [[ -d "$src" ]] || return 0
    if ! python3 -c 'import ensurepip, venv' >/dev/null 2>&1; then
        warn 'PKINITtools: python3-venv is not installed (see the APT notes); skipped'
        return 0
    fi
    if [[ ! -x "$venv/bin/python" ]] || ! "$venv/bin/python" -c 'import minikerberos, oscrypto, impacket' >/dev/null 2>&1; then
        info 'Building the PKINITtools Python environment...'
        rm -rf -- "$venv"
        python3 -m venv "$venv"
        "$venv/bin/pip" install -q --upgrade pip >/dev/null
        "$venv/bin/pip" install -q impacket minikerberos 'oscrypto @ git+https://github.com/wbond/oscrypto.git' >/dev/null
    fi
    for f in gettgtpkinit.py getnthash.py gets4uticket.py; do
        wrap "$f" "$venv/bin/python" "$src/$f" || true
    done
    ok 'PKINITtools: gettgtpkinit.py, getnthash.py, gets4uticket.py'
}

install_pipx_tools() {
    have pipx || { warn 'pipx is not installed (see the APT notes); pipx tools skipped'; return 0; }
    info 'Installing Python tools with pipx (isolated, in your home)...'
    pipx_get pywhisker 'git+https://github.com/ShutdownRepo/pywhisker.git'
    pipx_get adidnsdump adidnsdump
    pipx_get defaultcreds-cheat-sheet defaultcreds-cheat-sheet
    pipx_get git-dumper git-dumper
    pipx_get uploadserver uploadserver
    pipx_get wesng wesng
    pipx_get o365spray 'git+https://github.com/0xZDH/o365spray.git'
    pipx_get pre2k 'git+https://github.com/garrettfoster13/pre2k.git'
    pipx_get droopescan droopescan
    pipx_get bashfuscator 'git+https://github.com/Bashfuscator/Bashfuscator.git'
    have wsgidav || pipx_get wsgidav wsgidav cheroot
    alias_cmd pywhisker.py pywhisker
    ok 'pipx tools: pywhisker, adidnsdump, creds, git-dumper, uploadserver, wes, wsgidav, ...'
}

install_release_binaries() {
    local w="$TOOLS/windows"
    info 'Downloading release binaries from GitHub...'
    gh_release ropnop/kerbrute '^kerbrute_linux_amd64$' "$MANAGED_BIN/dl"
    if [[ -s "$MANAGED_BIN/dl/kerbrute_linux_amd64" ]]; then
        install -m 0755 -- "$MANAGED_BIN/dl/kerbrute_linux_amd64" "$MANAGED_BIN/kerbrute"
        wrap kerbrute '' "$MANAGED_BIN/kerbrute" || true
    fi
    gh_release ropnop/go-windapsearch '^windapsearch-linux-amd64$' "$MANAGED_BIN/dl"
    if [[ -s "$MANAGED_BIN/dl/windapsearch-linux-amd64" ]]; then
        install -m 0755 -- "$MANAGED_BIN/dl/windapsearch-linux-amd64" "$MANAGED_BIN/windapsearch"
        wrap windapsearch '' "$MANAGED_BIN/windapsearch" || true
    fi
    gh_release ropnop/kerbrute '^kerbrute_windows_amd64\.exe$' "$w/kerbrute"
    gh_release BeichenDream/GodPotato '^GodPotato.*\.exe$' "$w/potatoes"
    gh_release itm4n/PrintSpoofer '^PrintSpoofer(32|64)\.exe$' "$w/potatoes"
    gh_release ohpe/juicy-potato '^JuicyPotato.*\.exe$' "$w/potatoes"
    gh_release antonioCoco/JuicyPotatoNG '\.zip$' "$w/potatoes"
    gh_release antonioCoco/RoguePotato '\.zip$' "$w/potatoes"
    gh_release antonioCoco/RunasCs '\.zip$' "$w/RunasCs"
    gh_release AlessandroZ/LaZagne '^LaZagne.*\.exe$' "$w/LaZagne"
    gh_release itm4n/PrivescCheck '^PrivescCheck\.ps1$' "$w/PrivescCheck"
    gh_release netwrix/pingcastle '\.zip$' "$w/PingCastle"
    gh_release nccgroup/SocksOverRDP '\.zip$' "$TOOLS/pivot/SocksOverRDP"
    if [[ ! -s "$w/Sysinternals/PsExec64.exe" ]]; then
        local tmp
        tmp="$(mktemp)"
        if curl -fsSL --retry 3 --connect-timeout 20 -o "$tmp" https://download.sysinternals.com/files/SysinternalsSuite.zip; then
            mkdir -p -- "$w/Sysinternals"
            unzip -q -o "$tmp" -d "$w/Sysinternals" || warn 'Sysinternals: unzip failed'
        else
            warn 'Sysinternals: download failed'
        fi
        rm -f -- "$tmp"
    fi
    ok 'Release binaries: kerbrute, windapsearch, potatoes, RunasCs, LaZagne, PrivescCheck, PingCastle, Sysinternals'
}

link_transfer_dirs() {
    local w="$TOOLS/windows" l="$TOOLS/linux" p="$TOOLS/pivot"
    safe_link /usr/share/windows-resources "$w/kali-windows-resources"
    safe_link /usr/share/windows-resources/binaries "$w/binaries"
    safe_link /usr/share/windows-resources/mimikatz "$w/mimikatz"
    safe_link /usr/share/windows-resources/rubeus "$w/rubeus"
    if [[ -d /usr/share/windows-resources/powersploit ]]; then
        safe_link /usr/share/windows-resources/powersploit "$w/PowerSploit"
    else
        safe_link /usr/share/powersploit "$w/PowerSploit"
    fi
    safe_link /usr/share/windows-resources/powercat "$w/powercat"
    safe_link /usr/share/nishang "$w/nishang"
    safe_link /usr/share/sharphound "$w/sharphound"
    safe_link /usr/share/peass/winpeas "$w/winpeas"
    safe_link /usr/share/peass/linpeas/linpeas.sh "$l/linpeas.sh"
    safe_link /usr/share/pspy "$l/pspy"
    safe_link /usr/share/chisel-common-binaries "$p/chisel"
    safe_link /usr/share/ligolo-ng-common-binaries "$p/ligolo-ng"
    safe_link /usr/share/webshells "$TOOLS/web/webshells"
    safe_link /usr/share/laudanum "$TOOLS/web/laudanum"
    install -m 0644 -- "$SCRIPT_DIR/tools/README.txt" "$TOOLS/README.txt"
    ok 'Transfer folders: ~/tools/windows, ~/tools/linux, ~/tools/pivot (see ~/tools/README.txt)'
}

install_tools() {
    section 'Tools'
    setup_directories
    optional 'Wordlists' install_wordlists
    optional 'Impacket names' install_impacket_names
    optional 'GitHub tools' install_git_tools
    optional 'PKINITtools' install_pkinittools
    optional 'pipx tools' install_pipx_tools
    optional 'Release binaries' install_release_binaries
    optional 'Command names' install_command_names
    optional 'Transfer folders' link_transfer_dirs
}

# ============================================================== verification
verify_desktop() {
    section 'Checks'
    check_configs "$HOME"
    python3 "$HOME/.config/i3/status.py" --once >/dev/null || die 'The i3 bar status script failed its self-test'
    python3 "$HOME/.config/i3/scripts/vm-autofit.py" --self-test >/dev/null \
        || warn 'The VMware resize helper failed its self-test (the desktop will not follow the window size)'
    bash "$HOME/.config/i3/scripts/set-wallpaper.sh" --check || warn 'Wallpaper check failed'
    local missing=() tool
    for tool in alacritty zsh tmux rofi; do
        have "$tool" || missing+=("$tool")
    done
    ((${#missing[@]} == 0)) || warn "Desktop: not installed (see the APT notes): $(words "${missing[@]}")"
    ok 'i3, bar, zsh, tmux and wallpaper checks passed'
}

readonly -a EXPECTED_COMMANDS=(
    nmap rustscan masscan autorecon ffuf gobuster feroxbuster dirsearch wfuzz whatweb nikto wpscan sqlmap burpsuite
    nxc netexec crackmapexec cme evil-winrm evil-winrm-py certipy-ad certipy bloodyad bloodhound-ce-python
    bloodhound-python bloodhound-start kerbrute windapsearch windapsearch.py ldapsearch ldapdomaindump ldeep
    enum4linux enum4linux-ng smbclient smbmap rpcclient responder Responder.py mitm6 coercer krbrelayx.py
    PetitPotam.py gettgtpkinit.py getnthash.py targetedKerberoast.py pywhisker gMSADumper.py noPac.py
    CVE-2021-1675.py adidnsdump snaffler secretsdump.py GetUserSPNs.py GetNPUsers.py psexec.py wmiexec.py
    smbexec.py ntlmrelayx.py smbserver.py mssqlclient.py lookupsid.py ticketer.py raiseChild.py
    hashcat john ssh2john.py office2john.py hydra cewl cupp username-anarchy creds gpp-decrypt
    msfconsole msfvenom searchsploit chisel ligolo-proxy sshuttle proxychains4 socat rlwrap penelope
    xfreerdp3 odat swaks smtp-user-enum onesixtyone snmpwalk ipmitool linpeas wes uploadserver goshs
    git-dumper firefox_decrypt.py
)

report_commands() {
    local cmd
    local -a missing=()
    for cmd in "${EXPECTED_COMMANDS[@]}"; do
        PATH="$LOCAL_BIN:$MANAGED_BIN:$SYSTEM_PATH" command -v -- "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
    done
    if ((${#missing[@]})); then
        warn "Commands not available: $(words "${missing[@]}")"
    fi
    ok "$(( ${#EXPECTED_COMMANDS[@]} - ${#missing[@]} ))/${#EXPECTED_COMMANDS[@]} key commands available from any directory"
}

print_summary() {
    printf '\n%s%sDone.%s Reboot (or log out) and pick %si3%s at the login screen.\n\n' \
        "$C_BOLD" "$C_GREEN" "$C_RESET" "$C_BOLD" "$C_RESET"
    printf '  %-16s %s\n' 'Tools' "$TOOLS  (index: ~/tools/README.txt)"
    printf '  %-16s %s\n' 'Wordlists' "$HOME/wordlists"
    printf '  %-16s %s\n' 'tmux logs' "$HOME/logs/tmux  (prefix + P)"
    printf '  %-16s %s\n' 'Screenshots' "$HOME/Pictures/Screenshots  (Print)"
    printf '  %-16s %s\n' 'Backups' "${BACKUP_DIR:-$BACKUP_ROOT}"
    printf '  %-16s %s\n' 'Log' "$LOG_FILE"
    if [[ -s "$ISSUES_FILE" ]]; then
        printf '\n%sNotes (%s) — nothing here breaks the desktop:%s\n' "$C_YELLOW" "$(wc -l < "$ISSUES_FILE")" "$C_RESET"
        sed 's/^/  - /' "$ISSUES_FILE"
    fi
    if ((BLOCKED_TOTAL > 0)); then
        printf '\n%s%s package(s) were skipped because installing them would have removed\n' "$C_YELLOW" "$BLOCKED_TOTAL"
        printf 'packages you have (Kali is behind its repository). To add them:%s\n' "$C_RESET"
        printf '    sudo apt update && sudo apt full-upgrade -y && sudo reboot\n'
        printf '    then run ./install.sh again (it only adds what is missing).\n'
    fi
    printf '\n%sBloodHound CE is installed but not set up; when you need it: sudo bloodhound-setup%s\n' "$C_DIM" "$C_RESET"
}

# ============================================================== main
main() {
    if (($#)); then
        case "$1" in
            -h|--help) sed -n '2,20p' "$0"; return 0 ;;
            *) die 'This installer takes no options. Run: ./install.sh' ;;
        esac
    fi
    require_normal_user
    require_kali
    choose_wallpaper
    start_sudo

    install_packages
    install_dotfiles
    apply_wallpaper
    optional 'tmux plugins' install_tmux_plugins
    configure_login_shell
    optional 'Firefox' install_firefox
    install_tools

    verify_desktop
    report_commands
    print_summary
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
