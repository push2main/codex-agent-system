#!/usr/bin/env python3
from __future__ import annotations

import subprocess
import sys


def main() -> int:
    if len(sys.argv) < 3:
        print("usage: run-with-timeout.py <seconds> <command> [args...]", file=sys.stderr)
        return 2

    timeout = int(sys.argv[1])
    command = sys.argv[2:]

    try:
        completed = subprocess.run(command, check=False, timeout=timeout)
    except subprocess.TimeoutExpired:
        print(f"TIMEOUT after {timeout} seconds: {' '.join(command)}", file=sys.stderr)
        return 124

    return completed.returncode


if __name__ == "__main__":
    raise SystemExit(main())
