#!/usr/bin/env python3
"""Small, dependency-free i3bar status generator for kali-clean.

Shows CPU, RAM, root filesystem free space, VPN IPv4 and date/time.  The VPN
block is clickable: left click copies the detected VPN IPv4 to the clipboard.
"""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import re
import select
import shutil
import subprocess
import sys
import time
from typing import Any

FG = "#a9a9a9"
FG_BRIGHT = "#d0d0d0"
SEPARATOR = "#2a2a2a"
VPN_RE = re.compile(r"^(tun|tap|wg|vpn|ppp|tailscale)")
DEFAULT_VPN_ORDER = ("tun0", "tun1", "tun2", "wg0", "wg1", "tap0", "tap1", "ppp0", "tailscale0")


def cpu_totals() -> tuple[int, int]:
    fields = Path("/proc/stat").read_text(encoding="utf-8").splitlines()[0].split()
    values = [int(v) for v in fields[1:]]
    # user nice system idle iowait irq softirq steal guest guest_nice
    idle = values[3] + (values[4] if len(values) > 4 else 0)
    non_idle = sum(values[0:3]) + sum(values[5:8])
    return idle + non_idle, idle


class CpuSampler:
    def __init__(self) -> None:
        self.total, self.idle = cpu_totals()

    def sample(self) -> int:
        total, idle = cpu_totals()
        delta_total = total - self.total
        delta_idle = idle - self.idle
        self.total, self.idle = total, idle
        if delta_total <= 0:
            return 0
        value = round(100 * (delta_total - delta_idle) / delta_total)
        return max(0, min(100, value))


def memory_text() -> str:
    values: dict[str, int] = {}
    with open("/proc/meminfo", "r", encoding="utf-8") as handle:
        for line in handle:
            key, _, rest = line.partition(":")
            if key in {"MemTotal", "MemAvailable"}:
                values[key] = int(rest.strip().split()[0])
    total = values.get("MemTotal", 0)
    available = values.get("MemAvailable", 0)
    used = max(0, total - available)
    return f"RAM {used / 1048576:.1f}Gi / {total / 1048576:.1f}Gi"


def disk_text() -> str:
    free = shutil.disk_usage("/").free
    gib = free / (1024 ** 3)
    if gib >= 100:
        return f"DISK {gib:.0f}G free"
    return f"DISK {gib:.1f}G free"


def _vpn_interfaces_from_env() -> list[str]:
    raw = os.environ.get("KALI_CLEAN_VPN_INTERFACES", "").strip()
    if not raw:
        return list(DEFAULT_VPN_ORDER)
    return [part for part in re.split(r"[\s,]+", raw) if part]


def vpn_info() -> tuple[str, str]:
    try:
        result = subprocess.run(
            ["ip", "-j", "-4", "addr", "show"],
            text=True,
            capture_output=True,
            timeout=2,
            check=False,
        )
        if result.returncode != 0:
            return "", ""
        data = json.loads(result.stdout or "[]")
    except (OSError, subprocess.SubprocessError, json.JSONDecodeError):
        return "", ""

    addresses: dict[str, str] = {}
    for entry in data:
        iface = str(entry.get("ifname", ""))
        if not iface:
            continue
        for addr in entry.get("addr_info", []):
            if addr.get("family") != "inet":
                continue
            ip = str(addr.get("local", ""))
            if ip and not ip.startswith("127."):
                addresses.setdefault(iface, ip)
                break

    for iface in _vpn_interfaces_from_env():
        if iface in addresses:
            return iface, addresses[iface]
    for iface, ip in addresses.items():
        if VPN_RE.match(iface):
            return iface, ip
    return "", ""


def block(text: str, *, name: str, min_width: str | None = None, color: str = FG) -> dict[str, Any]:
    item: dict[str, Any] = {
        "full_text": text,
        "name": name,
        "color": color,
        "separator": True,
        "separator_block_width": 10,
    }
    if min_width:
        item["min_width"] = min_width
        item["align"] = "right"
    return item


def make_blocks(cpu: CpuSampler) -> list[dict[str, Any]]:
    _, vpn_ip = vpn_info()
    return [
        block(f"CPU {cpu.sample()}%", name="cpu", min_width="CPU 100%"),
        block(memory_text(), name="memory", min_width="RAM 99.9Gi / 99.9Gi"),
        block(disk_text(), name="disk", min_width="DISK 999G free"),
        block(f"VPN {vpn_ip or '--'}", name="vpn", min_width="VPN 000.000.000.000", color=FG_BRIGHT),
        block(time.strftime("%A, %d %B %Y %H:%M:%S"), name="clock", color=FG_BRIGHT),
    ]


def copy_vpn() -> None:
    iface, ip = vpn_info()
    if not ip:
        return
    payload = ip.encode()
    copied = False
    for command in (["xclip", "-selection", "clipboard", "-in"], ["xsel", "--clipboard", "--input"]):
        if shutil.which(command[0]) is None:
            continue
        try:
            completed = subprocess.run(command, input=payload, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
            copied = completed.returncode == 0
        except OSError:
            copied = False
        if copied:
            break
    if shutil.which("notify-send"):
        message = f"{ip} ({iface})" if copied else f"Could not copy {ip}"
        subprocess.run(
            ["notify-send", "-a", "kali-clean", "VPN address" if not copied else "VPN address copied", message],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=False,
        )


def handle_click_line(line: str) -> None:
    value = line.strip()
    if not value or value == "[":
        return
    value = value.lstrip(",").strip()
    if not value or value in {"[", "]"}:
        return
    try:
        event = json.loads(value)
    except json.JSONDecodeError:
        return
    if event.get("name") == "vpn" and event.get("button") == 1:
        copy_vpn()


def run_stream() -> int:
    cpu = CpuSampler()
    # Give the CPU sampler a useful first delta without making login feel slow.
    time.sleep(0.08)
    print(json.dumps({"version": 1, "click_events": True}), flush=True)
    print("[", flush=True)
    first = True

    while True:
        prefix = "" if first else ","
        print(prefix + json.dumps(make_blocks(cpu), separators=(",", ":")), flush=True)
        first = False

        deadline = time.monotonic() + 1.0
        while True:
            timeout = deadline - time.monotonic()
            if timeout <= 0:
                break
            try:
                ready, _, _ = select.select([sys.stdin], [], [], timeout)
            except (OSError, ValueError):
                time.sleep(timeout)
                break
            if not ready:
                break
            line = sys.stdin.readline()
            if line == "":
                time.sleep(max(0.0, timeout))
                break
            handle_click_line(line)


def main() -> int:
    parser = argparse.ArgumentParser(add_help=True)
    parser.add_argument("--once", action="store_true", help="print one JSON block array and exit")
    parser.add_argument("--vpn-ip", action="store_true", help="print only the detected VPN IPv4")
    args = parser.parse_args()

    if args.vpn_ip:
        print(vpn_info()[1])
        return 0

    cpu = CpuSampler()
    if args.once:
        time.sleep(0.08)
        print(json.dumps(make_blocks(cpu)))
        return 0
    return run_stream()


if __name__ == "__main__":
    raise SystemExit(main())
