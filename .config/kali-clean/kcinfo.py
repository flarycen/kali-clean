#!/usr/bin/env python3
"""kali-clean shared helpers: VPN address, target address, clipboard copy.

Used by the i3 bar (status.py), the tmux status line and the zsh helpers so
all three always agree on what the VPN and target addresses are.

    python3 kcinfo.py vpn            print the VPN IPv4 (empty if none)
    python3 kcinfo.py target         print the target IP ($ip, persisted)
    python3 kcinfo.py tmux           tmux status-right fragment
    python3 kcinfo.py copy vpn       copy the VPN IPv4 to the clipboard
    python3 kcinfo.py copy target    copy the target IP to the clipboard

Standard library only. Every function fails soft: no output, exit 0.
"""

from __future__ import annotations

import ipaddress
import json
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

# Interface preference: OpenVPN tun first, then WireGuard, then the rest.
VPN_PREFIXES = ("tun", "wg", "tap", "ppp", "vpn", "tailscale")
# Exported variable names that count as "the target", in priority order.
TARGET_NAMES = ("ip", "IP", "target", "TARGET", "rhost", "RHOST")

CONFIG_DIR = Path(os.environ.get("XDG_CONFIG_HOME") or Path.home() / ".config") / "kali-clean"
SESSION_FILE = CONFIG_DIR / "session.env"


def _addresses() -> dict[str, str]:
    """Return {interface: first IPv4} for every interface with an IPv4."""
    try:
        result = subprocess.run(
            ["ip", "-j", "-4", "addr", "show"],
            capture_output=True, text=True, timeout=2, check=False,
        )
        data = json.loads(result.stdout or "[]") if result.returncode == 0 else []
    except (OSError, subprocess.SubprocessError, ValueError):
        return {}
    found: dict[str, str] = {}
    for entry in data if isinstance(data, list) else []:
        name = str(entry.get("ifname", ""))
        for addr in entry.get("addr_info", []) or []:
            local = str(addr.get("local", ""))
            if addr.get("family") == "inet" and local and not local.startswith("127."):
                found.setdefault(name, local)
                break
    return found


def vpn_ip() -> tuple[str, str]:
    """(interface, address) of the preferred VPN interface, or ("", "")."""
    addrs = _addresses()
    for prefix in VPN_PREFIXES:
        for name in addrs:  # `ip` lists interfaces in index order
            if name.startswith(prefix):
                return name, addrs[name]
    return "", ""


def _valid_target(value: str) -> bool:
    value = value.strip()
    if not value or len(value) > 253 or any(c.isspace() for c in value):
        return False
    try:
        ipaddress.ip_address(value)
        return True
    except ValueError:
        # Accept host names too (export ip=dc01.inlanefreight.local).
        return bool(re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9.-]*", value))


def target_ip() -> str:
    """The target from the persisted session variables (export ip=...)."""
    try:
        data = json.loads(SESSION_FILE.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        data = {}
    if not isinstance(data, dict):
        data = {}
    for name in TARGET_NAMES:
        value = data.get(name)
        if isinstance(value, str) and _valid_target(value):
            return value.strip()
    return ""


def notify(title: str, body: str) -> None:
    if shutil.which("notify-send"):
        subprocess.run(
            ["notify-send", "-a", "kali-clean", title, body],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False,
        )


def _set_selection(selection: str, payload: bytes) -> bool:
    for cmd in (["xsel", f"--{selection}", "--input"], ["xclip", "-selection", selection, "-in"]):
        if shutil.which(cmd[0]) is None:
            continue
        try:
            done = subprocess.run(cmd, input=payload, stdout=subprocess.DEVNULL,
                                  stderr=subprocess.DEVNULL, timeout=3, check=False)
        except (OSError, subprocess.SubprocessError):
            continue
        if done.returncode == 0:
            return True
    return False


def copy_to_clipboard(text: str) -> bool:
    """CLIPBOARD and PRIMARY, xsel first, so the copy reaches the VMware host
    (see clip-in.sh for why)."""
    payload = text.encode()
    copied = _set_selection("clipboard", payload)
    _set_selection("primary", payload)
    return copied


def copy(which: str) -> int:
    if which == "vpn":
        iface, value = vpn_ip()
        label = f"VPN {iface}" if iface else "VPN"
    elif which == "target":
        value, label = target_ip(), "Target"
    else:
        return 2
    if not value:
        notify(label, "nothing to copy")
        return 1
    ok = copy_to_clipboard(value)
    notify(f"{label} copied" if ok else f"{label}: copy failed", value)
    return 0 if ok else 1


def tmux_fragment() -> str:
    dim, val, sep = "#[fg=#71717a]", "#[fg=#ffffff]", "#[fg=#3f3f46]"
    parts = []
    target = target_ip()
    if target:
        parts.append(f"{dim}tgt {val}{target}")
    _, vpn = vpn_ip()
    parts.append(f"{dim}vpn {val}{vpn}" if vpn else f"{dim}vpn --")
    return f" {sep}· ".join(parts)


def main(argv: list[str]) -> int:
    if not argv:
        print(__doc__.strip())
        return 0
    cmd = argv[0]
    if cmd == "vpn":
        print(vpn_ip()[1])
    elif cmd == "target":
        print(target_ip())
    elif cmd == "tmux":
        print(tmux_fragment())
    elif cmd == "copy" and len(argv) == 2:
        return copy(argv[1])
    else:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
