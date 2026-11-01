"""Host discovery and the session file. Never imports poser or wx."""

import json
import os
import re
import subprocess
import sys

DEV_PORT = 47800
_IPV4 = re.compile(r"(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})")


def wsl_adapter_ip():
    """IPv4 of the Windows 'vEthernet (WSL...)' adapter, or None.

    The adapter only exists while WSL is running, and its address can change
    across reboots, so this is looked up at every start.
    """
    if sys.platform != "win32":
        return None
    try:
        out = subprocess.check_output(["ipconfig"], creationflags=0x08000000)  # CREATE_NO_WINDOW
    except (OSError, subprocess.CalledProcessError):
        return None
    in_wsl = False
    for line in out.decode("ascii", "replace").splitlines():
        if line and not line[0].isspace():
            in_wsl = "(WSL" in line
        elif in_wsl and "IPv4" in line:
            m = _IPV4.search(line)
            if m:
                return m.group(1)
    return None


def session_dir():
    return os.path.join(os.environ.get("APPDATA") or os.path.expanduser("~"), "PoserBridge")


def write_session(data, path=None):
    """Atomically write the session file; returns its path."""
    path = path or os.path.join(session_dir(), "session.json")
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(data, f, indent=2)
    os.replace(tmp, path)
    return path


def read_config(path=None):
    """Optional settings from <session dir>/config.json, e.g. {"mode": "strict"}."""
    path = path or os.path.join(session_dir(), "config.json")
    try:
        with open(path) as f:
            data = json.load(f)
    except OSError:
        return {}
    return data if isinstance(data, dict) else {}
