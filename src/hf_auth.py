#!/usr/bin/env python3
from __future__ import annotations

import json
import subprocess
import sys
from shutil import which

try:
    from huggingface_hub import HfApi, get_token
except ImportError as exc:
    raise SystemExit(
        "huggingface_hub is not installed. Install OphanimAV dependencies first."
    ) from exc


def identity() -> dict:
    token = get_token()
    if not token:
        return {"connected": False, "username": None, "fullname": None}
    try:
        info = HfApi().whoami(token=token)
    except Exception as exc:
        return {"connected": False, "username": None, "fullname": None, "error": str(exc)}
    return {
        "connected": True,
        "username": info.get("name"),
        "fullname": info.get("fullname"),
    }


def cli(args: list[str]) -> int:
    exe = which("hf") or which("huggingface-cli")
    if not exe:
        print("ERROR: Hugging Face CLI is unavailable.", file=sys.stderr)
        return 1
    return subprocess.call([exe, *args])


def main() -> int:
    cmd = sys.argv[1] if len(sys.argv) > 1 else "status"
    if cmd == "status":
        data = identity()
        print("Hugging Face")
        print("============")
        print("Status:", "connected" if data["connected"] else "disconnected")
        if data.get("username"):
            print("Account:", data["username"])
        if data.get("fullname"):
            print("Name:   ", data["fullname"])
        if data.get("error"):
            print("Error:  ", data["error"])
        return 0 if data["connected"] else 1
    if cmd == "login":
        print("Authentication is delegated to huggingface_hub; OphanimAV does not store your token.")
        return cli(["auth", "login"])
    if cmd == "logout":
        return cli(["auth", "logout"])
    if cmd == "json":
        print(json.dumps(identity(), indent=2))
        return 0
    print("Usage: hf_auth.py {status|login|logout|json}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
