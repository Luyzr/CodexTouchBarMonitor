#!/usr/bin/env python3
"""Offline account protocol fixture. Uses only the injected disposable CODEX_HOME."""
import json, os, pathlib, sys
home = pathlib.Path(os.environ["CODEX_HOME"])
assert home == pathlib.Path(os.environ["CODEX_SQLITE_HOME"])
assert pathlib.Path.cwd() == home
assert 'cli_auth_credentials_store="file"' in sys.argv
scenario = (home.parent / "scenario").read_text()
def send(value):
    print(json.dumps(value), flush=True)
for line in sys.stdin:
    request = json.loads(line)
    if "id" not in request:
        continue
    method = request["method"]
    result = {}
    if method == "config/read":
        result = {"config": {"cli_auth_credentials_store": "keyring" if scenario == "policy" else "file"}}
    elif method == "account/login/start":
        result = {"loginId": "fixture-login", "authUrl": "https://auth.openai.com/fixture"}
        (home / "login-started").touch()
        if scenario != "cancel":
            (home / "auth.json").write_text('{"fixture":true}')
            send({"method": "account/login/completed", "params": {"loginId": "wrong" if scenario == "mismatch" else "fixture-login", "success": True}})
    elif method == "account/read":
        result = {"account": {"type": "chatgpt", "email": "fixture@example.invalid", "planType": "pro"}}
    elif method == "account/rateLimits/read":
        if scenario == "failure":
            send({"id": request["id"], "error": {"code": -1, "message": "fixture"}})
            continue
        result = {"rateLimits": {"secondary": {"usedPercent": 25, "windowDurationMins": 10080}}}
    send({"id": request["id"], "result": result})
