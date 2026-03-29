#!/usr/bin/env python3
from __future__ import annotations

import os
import signal
import subprocess
import sys


def main() -> int:
    if len(sys.argv) < 3:
        print("usage: run-with-timeout.py <seconds> <command> [args...]", file=sys.stderr)
        return 2

    timeout = int(sys.argv[1])
    command = sys.argv[2:]
    kwargs: dict[str, object] = {}
    if os.name == "posix":
        # Run the child in its own session so timeout cleanup can terminate the
        # full subprocess tree rather than leaving nested agent processes alive.
        kwargs["start_new_session"] = True

    process = subprocess.Popen(command, **kwargs)

    try:
        return process.wait(timeout=timeout)
    except subprocess.TimeoutExpired:
        if process.poll() is None:
            try:
                if os.name == "posix":
                    os.killpg(process.pid, signal.SIGTERM)
                else:
                    process.terminate()
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                try:
                    if os.name == "posix":
                        os.killpg(process.pid, signal.SIGKILL)
                    else:
                        process.kill()
                    process.wait(timeout=5)
                except (ProcessLookupError, subprocess.TimeoutExpired):
                    pass
            except ProcessLookupError:
                pass
        print(f"TIMEOUT after {timeout} seconds: {' '.join(command)}", file=sys.stderr)
        return 124


if __name__ == "__main__":
    raise SystemExit(main())
