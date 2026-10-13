"""Exercise deployment with fake tools; no builds, signing or device writes occur."""

import json
import os
from pathlib import Path
import subprocess
import sys

import pytest

SCRIPT = Path(__file__).resolve().parents[2] / "scripts" / "deploy-all.sh"


@pytest.mark.parametrize("dry_run", [False, True])
@pytest.mark.parametrize("account_error", [None, "No Accounts", "Failed to load credentials"])
def test_install_and_launch_run_the_command_with_all_arguments(tmp_path, dry_run, account_error):
    tools = tmp_path / "bin"
    tools.mkdir()
    calls = tmp_path / "calls.jsonl"
    xcrun = tools / "xcrun"
    xcrun.write_text(f"#!{sys.executable}\n" + """
import json, os, pathlib, sys
args = sys.argv[1:]
if args[:3] == ['devicectl', 'list', 'devices']:
    pathlib.Path(args[args.index('--json-output') + 1]).write_text(json.dumps({'result': {'devices': [
        {'identifier': 'device-id', 'hardwareProperties': {'reality': 'physical', 'udid': 'hardware-id',
         'deviceType': 'iPhone', 'marketingName': 'Test Phone'}}]}}))
else:
    with open(os.environ['TEST_DEPLOY_CALLS'], 'a') as f:
        f.write(json.dumps(args) + '\\n')
""")
    xcrun.chmod(0o755)
    xcodebuild = tools / "xcodebuild"
    xcodebuild.write_text("#!/bin/bash\nprintf '%s\\n' \"${TEST_ACCOUNT_ERROR:-}\"\necho '** BUILD SUCCEEDED **'\n")
    xcodebuild.chmod(0o755)
    pgrep = tools / "pgrep"
    pgrep.write_text("#!/bin/bash\nexit 1\n")
    pgrep.chmod(0o755)
    ioreg = tools / "ioreg"
    ioreg.write_text('#!/bin/bash\necho \'"CGSSessionScreenIsLocked" = No\'\n')
    ioreg.chmod(0o755)
    caffeinate = tools / "caffeinate"
    caffeinate.write_text(f"#!{sys.executable}\nimport signal\nsignal.pause()\n")
    caffeinate.chmod(0o755)
    devicectl = tools / "devicectl"
    devicectl.write_text("#!/bin/bash\necho 'xcrun was dropped from the command' >&2\nexit 1\n")
    devicectl.chmod(0o755)
    config = tmp_path / "apps.json"
    config.write_text(json.dumps({"apps": [{"name": "app", "bundle": "app.bundle", "repo": str(tmp_path),
        "build": {"scheme": "App", "project": "App.xcodeproj", "app": "Build/My App.app"}}]}))
    env = {**os.environ, "PATH": f"{tools}:{os.environ['PATH']}", "BUG_KIT_CONFIG": str(config),
           "BUG_KIT_LOCKED": "1", "TEST_DEPLOY_CALLS": str(calls), "TEST_ACCOUNT_ERROR": account_error or ""}
    args = ["/bin/bash", str(SCRIPT), "app"] + (["--dry-run"] if dry_run else [])
    result = subprocess.run(args, env=env, capture_output=True, text=True, timeout=10)
    if account_error and not dry_run:
        assert result.returncode == 78, result.stdout + result.stderr
        assert "do not retry" in result.stderr
        assert not calls.exists()  # even BUILD SUCCEEDED must not install after account loss
        return
    assert result.returncode == 0, result.stdout + result.stderr
    if dry_run:
        assert not calls.exists()
        assert "dry run: nothing was" in result.stdout
        return
    assert [json.loads(line) for line in calls.read_text().splitlines()] == [
        ["devicectl", "device", "install", "app", "--device", "device-id", "Build/My App.app"],
        ["devicectl", "device", "process", "launch", "--device", "device-id", "app.bundle"],
    ]
