#!/usr/bin/env python3
"""kali-clean i3bar status: CPU, RAM, disk, VPN IP, target IP, date/time.

Click the VPN or TARGET block (left button) to copy that address.
Standard library only; never exits on its own errors.

    status.py            stream for i3bar (status_command)
    status.py --once     print one block array and exit (self-test)
"""

from __future__ import annotations

import argparse
import html
import json
import os
import select
import shutil
import sys
import time
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(os.environ.get("XDG_CONFIG_HOME") or Path.home() / ".config") / "kali-clean"))
try:
    import kcinfo  # shared with tmux and zsh
except Exception:  # pragma: no cover - keep the bar alive without the helper
    kcinfo = None

LABEL = "#71717a"
VALUE = "#f5f5f5"
BRIGHT = "#ffffff"
EMPTY = "#52525b"


def cpu_totals() -> tuple[int, int]:
    with open("/proc/stat", encoding="utf-8") as fh:
        fields = fh.readline().split()
    values = [int(v) for v in fields[1:]]
    idle = values[3] + (values[4] if len(values) > 4 else 0)
    busy = sum(values[0:3]) + sum(values[5:8])
    return idle + busy, idle


class CpuSampler:
    def __init__(self) -> None:
        self.total, self.idle = cpu_totals()

    def sample(self) -> int:
        total, idle = cpu_totals()
        d_total, d_idle = total - self.total, idle - self.idle
        self.total, self.idle = total, idle
        if d_total <= 0:
            return 0
        return max(0, min(100, round(100 * (d_total - d_idle) / d_total)))


def memory() -> tuple[float, float]:
    values: dict[str, int] = {}
    with open("/proc/meminfo", encoding="utf-8") as fh:
        for line in fh:
            key, _, rest = line.partition(":")
            if key in ("MemTotal", "MemAvailable"):
                values[key] = int(rest.split()[0])
    total = values.get("MemTotal", 0) / 1048576
    used = max(0.0, total - values.get("MemAvailable", 0) / 1048576)
    return used, total


def disk_free_gib() -> float:
    return shutil.disk_usage("/").free / (1024 ** 3)


def span(text: str, color: str, bold: bool = False) -> str:
    weight = " font_weight='bold'" if bold else ""
    return f"<span foreground='{color}'{weight}>{html.escape(text)}</span>"


def block(name: str, label: str, value: str, *, value_color: str = VALUE, bold: bool = False) -> dict[str, Any]:
    text = (span(label, LABEL) + " " if label else "") + span(value, value_color, bold)
    return {
        "name": name,
        "full_text": text,
        "markup": "pango",
        "separator": False,
        "separator_block_width": 22,
    }


def make_blocks(cpu: CpuSampler) -> list[dict[str, Any]]:
    used, total = memory()
    free = disk_free_gib()
    vpn = kcinfo.vpn_ip()[1] if kcinfo else ""
    target = kcinfo.target_ip() if kcinfo else ""
    return [
        block("cpu", "CPU", f"{cpu.sample()}%"),
        block("memory", "RAM", f"{used:.1f}/{total:.1f}G"),
        block("disk", "DISK", f"{free:.0f}G free"),
        block("vpn", "VPN", vpn or "--", value_color=BRIGHT if vpn else EMPTY, bold=bool(vpn)),
        block("target", "TARGET", target or "--", value_color=BRIGHT if target else EMPTY, bold=bool(target)),
        block("clock", "", time.strftime("%a %d %b %Y  %H:%M:%S") + " ", value_color=VALUE),
    ]


def safe_blocks(cpu: CpuSampler) -> list[dict[str, Any]]:
    try:
        return make_blocks(cpu)
    except Exception as exc:  # never let i3bar show "status_command process exited"
        return [{"name": "error", "full_text": f"status: {exc}", "color": "#f87171"}]


def handle_click(line: str) -> None:
    value = line.strip().lstrip(",").strip()
    if not value or value in ("[", "]"):
        return
    try:
        event = json.loads(value)
    except ValueError:
        return
    if event.get("button") != 1 or kcinfo is None:
        return
    if event.get("name") == "vpn":
        kcinfo.copy("vpn")
    elif event.get("name") == "target":
        kcinfo.copy("target")


def run_stream() -> int:
    cpu = CpuSampler()
    time.sleep(0.1)  # give the CPU sampler a first delta
    print(json.dumps({"version": 1, "click_events": True}), flush=True)
    print("[", flush=True)
    first = True
    stdin_open = True
    while True:
        print(("" if first else ",") + json.dumps(safe_blocks(cpu), separators=(",", ":")), flush=True)
        first = False
        deadline = time.monotonic() + 1.0
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                break
            if not stdin_open:
                time.sleep(remaining)
                break
            try:
                ready, _, _ = select.select([sys.stdin], [], [], remaining)
            except (OSError, ValueError):
                stdin_open = False
                continue
            if not ready:
                break
            line = sys.stdin.readline()
            if line == "":
                stdin_open = False  # i3bar closed our stdin; keep printing
                continue
            handle_click(line)


def main() -> int:
    parser = argparse.ArgumentParser(description="kali-clean i3bar status")
    parser.add_argument("--once", action="store_true", help="print one block array and exit")
    args = parser.parse_args()
    if args.once:
        cpu = CpuSampler()
        time.sleep(0.1)
        print(json.dumps(safe_blocks(cpu)))
        return 0
    try:
        return run_stream()
    except (BrokenPipeError, KeyboardInterrupt):
        return 0


if __name__ == "__main__":
    raise SystemExit(main())
