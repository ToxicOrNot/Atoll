#!/usr/bin/env python3
"""Forward an explicit local Codex approval to Atoll, with native UI fallback."""

import json
import os
from pathlib import Path
import shutil
import stat
import sys
import time
import uuid


ROOT = Path.home() / "Library" / "Application Support" / "Atoll" / "CodexApprovals"
MAX_INPUT = 96 * 1024
DISPLAY_GRACE = 2.5
DECISION_TIMEOUT = 75


def is_private_directory(path):
    info = path.lstat()
    return (
        stat.S_ISDIR(info.st_mode)
        and info.st_uid == os.getuid()
        and not info.st_mode & 0o077
    )


def read_reply(path):
    try:
        descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    except FileNotFoundError:
        return None

    with os.fdopen(descriptor, "rb") as reply:
        info = os.fstat(reply.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid():
            return None
        return reply.read(32).decode("ascii")


def ask_atoll(event, root=ROOT):
    tool = event.get("tool_name")
    tool_input = event.get("tool_input")
    cwd = (tool_input.get("workdir") if isinstance(tool_input, dict) else None)
    cwd = cwd or event.get("tool_cwd") or event.get("cwd")
    if (
        event.get("hook_event_name") != "PermissionRequest"
        or not isinstance(tool, str)
        or tool not in {"Bash", "apply_patch"}
        or not isinstance(tool_input, dict)
        or not isinstance(tool_input.get("command"), str)
        or not tool_input["command"].strip()
        or not isinstance(cwd, str)
        or not cwd
    ):
        return None

    request_id = str(uuid.uuid4())
    now = time.time()
    # Escape control and bidi characters in the displayed tool data.
    body = json.dumps(
        {
            "id": request_id,
            "createdAt": now,
            "expiresAt": now + DECISION_TIMEOUT,
            "tool": tool,
            "directory": json.dumps(cwd, ensure_ascii=True)[1:-1],
            "input": json.dumps(tool_input, ensure_ascii=True, indent=2, sort_keys=True),
        }
    ).encode("utf-8")
    if len(body) > MAX_INPUT:
        return None

    root.mkdir(mode=0o700, parents=True, exist_ok=True)
    if not is_private_directory(root):
        return None

    directory = root / request_id
    directory.mkdir(mode=0o700)
    try:
        temporary = directory / "request.tmp"
        with temporary.open("xb") as stream:
            stream.write(body)
        temporary.replace(directory / "request.json")
        start = time.monotonic()
        while time.monotonic() - start < DECISION_TIMEOUT:
            decision = read_reply(directory / "reply")
            if decision in {"allow", "deny"}:
                return decision
            if decision == "deferToCodex":
                return None
            if time.monotonic() - start >= DISPLAY_GRACE and not (directory / "seen").is_file():
                return None
            time.sleep(0.1)
        return None
    finally:
        shutil.rmtree(directory, ignore_errors=True)


def main():
    os.umask(0o077)
    try:
        payload = sys.stdin.buffer.read(MAX_INPUT + 1)
        event = json.loads(payload) if len(payload) <= MAX_INPUT else None
        decision = ask_atoll(event) if isinstance(event, dict) else None
    except (OSError, ValueError):
        decision = None

    output = {}
    if decision in {"allow", "deny"}:
        output["hookSpecificOutput"] = {
            "hookEventName": "PermissionRequest",
            "decision": {"behavior": decision},
        }
    print(json.dumps(output))


if __name__ == "__main__":
    main()
