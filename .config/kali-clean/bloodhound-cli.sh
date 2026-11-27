#!/usr/bin/env bash
# kali-clean: SpecterOps' bloodhound-cli (BloodHound CE in Docker) with the
# Docker plumbing handled for you.
#
#  * Kali keeps network services off until you need them, Docker included, so
#    commands that use containers start it first (sudo systemctl start docker).
#    It is not enabled at boot.
#  * install.sh adds you to the docker group, which a login session only picks
#    up after you log out and back in. Until then this runs through `sg docker`.
#  * Ports (~/.config/bloodhound/.env, written by install.sh): BloodHound UI on
#    127.0.0.1:8888, so 8080 stays free for Burp; neo4j on 7475/7688, so it does
#    not clash with Kali's own bloodhound package (neo4j on 7474/7687).
#
# The real binary is ~/.local/share/kali-clean/bin/bloodhound-cli.
set -u

home="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
real="$home/.local/share/kali-clean/bin/bloodhound-cli"
me="$(id -un)"

if [[ ! -x "$real" ]]; then
    echo "bloodhound-cli: not installed; run kali-clean's ./install.sh again" >&2
    exit 1
fi
if [[ $(id -u) -eq 0 && -n "${SUDO_USER:-}" ]]; then
    echo "bloodhound-cli: run it without sudo. It starts Docker and handles access itself;" >&2
    echo "as root it would set up a separate BloodHound in /root/.config/bloodhound." >&2
    exit 1
fi

case "${1:-}" in                    # these never touch Docker
    ''|-h|--help|help|version|config|completion) exec "$real" "$@" ;;
esac

if command -v docker >/dev/null 2>&1; then
    if ! systemctl is-active --quiet docker.service docker.socket 2>/dev/null; then
        echo "bloodhound-cli: starting Docker (sudo systemctl start docker)..." >&2
        sudo systemctl start docker.service || exit 1
    fi
    in_group() { tr ' ' '\n' | grep -qx docker; }
    if [[ $(id -u) -ne 0 ]] && ! id -nG | in_group; then
        if id -nG "$me" | in_group; then
            # In the docker group since install.sh, but not in this login session yet.
            quote() { printf "'%s'" "${1//\'/\'\\\'\'}"; }
            cmd="exec $(quote "$real")"
            for arg in "$@"; do cmd+=" $(quote "$arg")"; done
            exec sg docker -c "$cmd"
        fi
        echo "bloodhound-cli: $me may not use Docker yet. Run: sudo usermod -aG docker $me" >&2
        echo "then log out and back in (or run ./install.sh again)." >&2
        exit 1
    fi
fi
exec "$real" "$@"
