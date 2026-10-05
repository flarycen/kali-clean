#!/usr/bin/env python3
"""Persist user-created exported variables across zsh and tmux sessions.

The zsh bridge calls this helper at shell startup, after commands, and just
before an entered command executes. Only variables created after shell startup
are auto-persisted; ordinary login/session state is excluded. Persistent values
live in ~/.config/kali-clean/session.env as JSON with mode 0600.
"""

from __future__ import annotations

import argparse
import fcntl
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tempfile
import time
from typing import Dict, Iterable, Set

CONFIG_DIR = Path(os.environ.get("XDG_CONFIG_HOME", Path.home() / ".config")) / "kali-clean"
PERSIST_FILE = CONFIG_DIR / "session.env"
LOCK_FILE = CONFIG_DIR / ".session.env.lock"
RUNTIME_BASE = Path(os.environ.get("XDG_RUNTIME_DIR", Path.home() / ".cache")) / "kali-clean" / "env-sync"

TRANSIENT_EXACT = {
    "PATH", "HOME", "USER", "LOGNAME", "SHELL", "PWD", "OLDPWD", "SHLVL", "_",
    "TERM", "TERM_PROGRAM", "COLORTERM", "DISPLAY", "WAYLAND_DISPLAY", "WINDOWID",
    "XAUTHORITY", "DBUS_SESSION_BUS_ADDRESS", "TMUX", "TMUX_PANE", "STY",
    "DESKTOP_SESSION", "GDMSESSION", "SESSION_MANAGER", "LS_COLORS", "LESSOPEN",
    "LESSCLOSE",
}
TRANSIENT_PREFIXES = ("XDG_", "SSH_")
SENSITIVE_FRAGMENTS = ("PASSWORD", "PASSWD", "TOKEN", "SECRET", "COOKIE", "API_KEY", "PRIVATE_KEY")


def valid_name(name: str) -> bool:
    return bool(name) and (name[0].isalpha() or name[0] == "_") and all(c.isalnum() or c == "_" for c in name)


def auto_blocked(name: str) -> bool:
    if name in TRANSIENT_EXACT or name.startswith(TRANSIENT_PREFIXES):
        return True
    upper = name.upper()
    return any(fragment in upper for fragment in SENSITIVE_FRAGMENTS)


def ensure_dirs() -> None:
    CONFIG_DIR.mkdir(parents=True, exist_ok=True, mode=0o700)
    RUNTIME_BASE.mkdir(parents=True, exist_ok=True, mode=0o700)
    try:
        CONFIG_DIR.chmod(0o700)
        RUNTIME_BASE.chmod(0o700)
    except OSError:
        pass


def read_json(path: Path, default):
    try:
        with path.open("r", encoding="utf-8") as fh:
            data = json.load(fh)
        return data
    except (FileNotFoundError, json.JSONDecodeError, OSError):
        return default


def atomic_json(path: Path, data, mode: int = 0o600) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        os.fchmod(fd, mode)
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            json.dump(data, fh, ensure_ascii=False, sort_keys=True, indent=2)
            fh.write("\n")
            fh.flush()
            os.fsync(fh.fileno())
        os.replace(tmp_name, path)
        os.chmod(path, mode)
    finally:
        try:
            os.unlink(tmp_name)
        except FileNotFoundError:
            pass


def shell_files(shell_pid: str) -> tuple[Path, Path]:
    if not shell_pid.isdigit():
        raise ValueError("invalid shell pid")
    return RUNTIME_BASE / f"{shell_pid}.baseline.json", RUNTIME_BASE / f"{shell_pid}.state.json"


def shell_export(name: str, value: str) -> str:
    return f"export {name}={shlex.quote(value)}"


def shell_unset(name: str) -> str:
    return f"unset -- {name}"


def update_tmux_set(name: str, value: str) -> None:
    if shutil.which("tmux") is None:
        return
    subprocess.run(["tmux", "set-environment", "-g", name, value], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    sessions = subprocess.run(
        ["tmux", "list-sessions", "-F", "#{session_name}"],
        text=True, capture_output=True, check=False,
    )
    if sessions.returncode == 0:
        for session in sessions.stdout.splitlines():
            if session:
                subprocess.run(["tmux", "set-environment", "-t", session, name, value], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def update_tmux_unset(name: str) -> None:
    if shutil.which("tmux") is None:
        return
    subprocess.run(["tmux", "set-environment", "-gu", name], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    sessions = subprocess.run(
        ["tmux", "list-sessions", "-F", "#{session_name}"],
        text=True, capture_output=True, check=False,
    )
    if sessions.returncode == 0:
        for session in sessions.stdout.splitlines():
            if session:
                subprocess.run(["tmux", "set-environment", "-u", "-t", session, name], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def cleanup_runtime() -> None:
    cutoff = time.time() - (7 * 24 * 60 * 60)
    for path in RUNTIME_BASE.glob("*.json"):
        try:
            if path.stat().st_mtime < cutoff:
                path.unlink()
        except OSError:
            pass


def locked_file():
    ensure_dirs()
    fh = LOCK_FILE.open("a+", encoding="utf-8")
    os.chmod(LOCK_FILE, 0o600)
    fcntl.flock(fh.fileno(), fcntl.LOCK_EX)
    return fh


def load_persistent() -> Dict[str, str]:
    data = read_json(PERSIST_FILE, {})
    if not isinstance(data, dict):
        return {}
    return {str(k): str(v) for k, v in data.items() if valid_name(str(k))}


def cmd_init(shell_pid: str) -> int:
    ensure_dirs()
    cleanup_runtime()
    baseline_file, state_file = shell_files(shell_pid)

    # Capture environment BEFORE applying persisted user variables.
    baseline_names = sorted(os.environ.keys())
    atomic_json(baseline_file, baseline_names)

    with locked_file() as lock:
        persistent = load_persistent()
        atomic_json(state_file, {"last": persistent, "ignored": []})
    del lock

    for name, value in persistent.items():
        print(shell_export(name, value))
        update_tmux_set(name, value)
    return 0


def read_state(state_file: Path) -> tuple[Dict[str, str], Set[str]]:
    raw = read_json(state_file, {"last": {}, "ignored": []})
    if not isinstance(raw, dict):
        return {}, set()
    last_raw = raw.get("last", {})
    ignored_raw = raw.get("ignored", [])
    last = {str(k): str(v) for k, v in last_raw.items()} if isinstance(last_raw, dict) else {}
    ignored = {str(v) for v in ignored_raw} if isinstance(ignored_raw, list) else set()
    return last, ignored


def cmd_sync(shell_pid: str) -> int:
    ensure_dirs()
    baseline_file, state_file = shell_files(shell_pid)
    baseline_raw = read_json(baseline_file, list(os.environ.keys()))
    baseline = {str(v) for v in baseline_raw} if isinstance(baseline_raw, list) else set(os.environ.keys())
    last, ignored = read_state(state_file)
    current = dict(os.environ)
    shell_actions: list[str] = []
    tmux_sets: list[tuple[str, str]] = []
    tmux_unsets: list[str] = []

    with locked_file() as lock:
        remote = load_persistent()
        final = dict(remote)
        tracked = set(last) | set(remote)
        new_last = dict(last)

        for name in tracked:
            local_exists = name in current
            remote_exists = name in remote
            last_exists = name in last

            if last_exists:
                local_changed = (not local_exists) or current[name] != last[name]
                remote_changed = (not remote_exists) or remote[name] != last[name]
            else:
                local_changed = local_exists
                remote_changed = remote_exists

            # Changes made in this shell take precedence over a simultaneous remote update.
            if local_changed:
                if local_exists:
                    final[name] = current[name]
                    new_last[name] = current[name]
                    ignored.discard(name)
                    tmux_sets.append((name, current[name]))
                else:
                    final.pop(name, None)
                    new_last.pop(name, None)
                    ignored.add(name)
                    tmux_unsets.append(name)
            elif remote_changed:
                if remote_exists:
                    shell_actions.append(shell_export(name, remote[name]))
                    new_last[name] = remote[name]
                    ignored.discard(name)
                    tmux_sets.append((name, remote[name]))
                else:
                    shell_actions.append(shell_unset(name))
                    new_last.pop(name, None)
                    ignored.add(name)
                    tmux_unsets.append(name)
            elif remote_exists:
                new_last[name] = remote[name]

        # Auto-discover exported variables created by the user after startup.
        for name, value in current.items():
            if name in baseline or name in new_last or name in ignored:
                continue
            if not valid_name(name) or auto_blocked(name):
                continue
            final[name] = value
            new_last[name] = value
            tmux_sets.append((name, value))

        if final != remote:
            atomic_json(PERSIST_FILE, final)
        elif PERSIST_FILE.exists():
            try:
                os.chmod(PERSIST_FILE, 0o600)
            except OSError:
                pass

        atomic_json(state_file, {"last": new_last, "ignored": sorted(ignored)})
    del lock

    for name, value in tmux_sets:
        update_tmux_set(name, value)
    for name in tmux_unsets:
        update_tmux_unset(name)
    for action in shell_actions:
        print(action)
    return 0


def cmd_set(shell_pid: str, name: str, value: str, force: bool) -> int:
    if not valid_name(name):
        print("invalid environment variable name", file=sys.stderr)
        return 2
    if auto_blocked(name) and not force:
        print(
            f"Refusing to persist '{name}' automatically. Use --force if you deliberately want it stored in {PERSIST_FILE}.",
            file=sys.stderr,
        )
        return 2

    _, state_file = shell_files(shell_pid)
    last, ignored = read_state(state_file)
    with locked_file() as lock:
        values = load_persistent()
        values[name] = value
        atomic_json(PERSIST_FILE, values)
        last[name] = value
        ignored.discard(name)
        atomic_json(state_file, {"last": last, "ignored": sorted(ignored)})
    del lock
    update_tmux_set(name, value)
    print(shell_export(name, value))
    return 0


def cmd_unpersist(shell_pid: str, name: str) -> int:
    if not valid_name(name):
        print("invalid environment variable name", file=sys.stderr)
        return 2
    _, state_file = shell_files(shell_pid)
    last, ignored = read_state(state_file)
    with locked_file() as lock:
        values = load_persistent()
        values.pop(name, None)
        atomic_json(PERSIST_FILE, values)
        last.pop(name, None)
        ignored.add(name)
        atomic_json(state_file, {"last": last, "ignored": sorted(ignored)})
    del lock
    update_tmux_unset(name)
    return 0


def cmd_list() -> int:
    with locked_file() as lock:
        values = load_persistent()
    del lock
    for name in sorted(values):
        print(f"{name}={shlex.quote(values[name])}")
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("--shell-pid", required=True)
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("init")
    sub.add_parser("sync")
    set_p = sub.add_parser("set")
    set_p.add_argument("--force", action="store_true")
    set_p.add_argument("name")
    set_p.add_argument("value")
    unset_p = sub.add_parser("unpersist")
    unset_p.add_argument("name")
    sub.add_parser("list")
    return parser


def main() -> int:
    args = build_parser().parse_args()
    try:
        if args.command == "init":
            return cmd_init(args.shell_pid)
        if args.command == "sync":
            return cmd_sync(args.shell_pid)
        if args.command == "set":
            return cmd_set(args.shell_pid, args.name, args.value, args.force)
        if args.command == "unpersist":
            return cmd_unpersist(args.shell_pid, args.name)
        if args.command == "list":
            return cmd_list()
    except (OSError, ValueError) as exc:
        print(f"kali-clean env sync: {exc}", file=sys.stderr)
        return 1
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
