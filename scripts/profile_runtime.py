#!/usr/bin/env python3
"""Short local resource sample, including owned child processes. Does not stop user's Codex."""
import argparse
import plistlib
import json
import pathlib
import subprocess
import time

argparse.ArgumentParser(description=__doc__).parse_args()
root = pathlib.Path(__file__).resolve().parent.parent
subprocess.run(['python3', str(root / 'scripts/check_build_host.py')], check=True)
version = plistlib.loads((root / 'Resources/Info.plist').read_bytes())['CFBundleShortVersionString']

def snapshot(pid):
    rows = {}
    for line in subprocess.check_output(['ps', '-axo', 'pid=,ppid=,rss=,time='], text=True).splitlines():
        parts = line.split()
        if len(parts) != 4:
            continue
        process, parent, rss = map(int, parts[:3])
        fields = list(map(float, parts[3].split(':')))
        seconds = sum(n * 60**i for i, n in enumerate(reversed(fields)))
        rows[process] = (parent, rss, seconds)
    children = {pid}
    while True:
        expanded = children | {child for child, row in rows.items() if row[0] in children}
        if expanded == children:
            break
        children = expanded
    return {child: rows[child] for child in children if child in rows}

with (root / f'work/smoke-{version}.log').open('w') as log:
    process = subprocess.Popen([str(root / '.build/release/CodexTouchBarMonitor'), '--disable-private-api', '--smoke-test'], stdout=log, stderr=log, cwd=root)
    try:
        time.sleep(4)
        first = snapshot(process.pid)
        started = time.monotonic()
        time.sleep(6)
        second = snapshot(process.pid)
        elapsed = time.monotonic() - started
        common = set(first) & set(second)
        cpu = sum(max(0, second[p][2] - first[p][2]) for p in common) / elapsed * 100
        report = dict(sampleSeconds=round(elapsed, 2), monitorRSSMiB=round(second.get(process.pid, (0, 0, 0))[1] / 1024, 2),
                      ownedProcessCount=len(second), ownedRSSMiB=round(sum(r[1] for r in second.values()) / 1024, 2),
                      ownedCPUPercent=round(cpu, 2), limitations='Short live sample, not a long-term idle benchmark; short-lived children may be missed')
        code = process.wait(timeout=10)
        if code:
            raise SystemExit(f'Smoke process failed: {code}')
    finally:
        if process.poll() is None:
            process.terminate()
            process.wait(timeout=5)
(root / f'work/performance-{version}.json').write_text(json.dumps(report, indent=2) + '\n')
print(json.dumps(report, indent=2))
