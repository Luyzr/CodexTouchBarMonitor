#!/usr/bin/env python3
"""Require an explicitly configured build machine; local configuration is never published."""
import json, pathlib, subprocess
root = pathlib.Path(__file__).resolve().parent.parent
config = root / "work/build-host.json"
if not config.exists():
    raise SystemExit("Configure work/build-host.json with hostname and root before building; see README.")
expected = json.loads(config.read_text())
if expected.get("hostname") != subprocess.check_output(["hostname", "-s"], text=True).strip() or expected.get("root") != str(root):
    raise SystemExit("This checkout is restricted to its configured build machine and directory.")
