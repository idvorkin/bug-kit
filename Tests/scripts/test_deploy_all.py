"""Exercise deployment with fake tools; no builds, signing or device writes occur."""

import json
import os
from pathlib import Path
import subprocess
import sys

import pytest

SCRIPT = Path(__file__).resolve().parents[2] / "scripts" / "deploy-all.sh"


UNLOCKED = '#!/bin/bash\necho \'"CGSSessionScreenIsLocked" = No\'\n'


def deploy(tmp_path, dry_run=False, account_error=None, ioreg_script=UNLOCKED, xcodebuild_fail=None,
           xcodebuild_note=None):
    tools = tmp_path / "bin"
    tools.mkdir(exist_ok=True)
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
    xcodebuild.write_text("#!/bin/bash\nprintf '%s\\n' \"${TEST_ACCOUNT_ERROR:-}\"\n"
                          "[ -n \"${TEST_XCODEBUILD_FAIL:-}\" ] && { printf '%s\\n' \"$TEST_XCODEBUILD_FAIL\"; exit 70; }\n"
                          "printf '%s\\n' \"${TEST_XCODEBUILD_NOTE:-}\"\n"
                          "echo '** BUILD SUCCEEDED **'\n")
    xcodebuild.chmod(0o755)
    pgrep = tools / "pgrep"
    pgrep.write_text("#!/bin/bash\nexit 1\n")
    pgrep.chmod(0o755)
    ioreg = tools / "ioreg"
    ioreg.write_text(ioreg_script)
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
           "BUG_KIT_LOCKED": "1", "TEST_DEPLOY_CALLS": str(calls), "TEST_ACCOUNT_ERROR": account_error or "",
           "TEST_XCODEBUILD_FAIL": xcodebuild_fail or "",
           "TEST_XCODEBUILD_NOTE": xcodebuild_note or ""}
    args = ["/bin/bash", str(SCRIPT), "app"] + (["--dry-run"] if dry_run else [])
    return subprocess.run(args, env=env, capture_output=True, text=True, timeout=10), calls


@pytest.mark.parametrize("dry_run", [False, True])
@pytest.mark.parametrize("account_error", [None, "No Accounts", "Failed to load credentials"])
def test_install_and_launch_run_the_command_with_all_arguments(tmp_path, dry_run, account_error):
    result, calls = deploy(tmp_path, dry_run, account_error)
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


def test_guard_wait_is_shown_on_stderr_and_the_build_still_installs(tmp_path):
    states = tmp_path / "locked-once"
    (tmp_path / "bin").mkdir()
    sleep = tmp_path / "bin" / "sleep"
    sleep.write_text("#!/bin/bash\nexit 0\n")
    sleep.chmod(0o755)
    ioreg = ("#!/bin/bash\n"
             f"if [ -e '{states}' ]; then echo '\"CGSSessionScreenIsLocked\" = No'; "
             f"else touch '{states}'; echo '\"CGSSessionScreenIsLocked\" = Yes'; fi\n")
    result, calls = deploy(tmp_path, ioreg_script=ioreg)
    assert result.returncode == 0, result.stdout + result.stderr
    assert "Mac is locked; waiting for the person to unlock it" in result.stderr
    assert "Mac unlocked; starting build" in result.stderr
    assert len(calls.read_text().splitlines()) == 2


def test_unreadable_lock_state_is_shown_and_nothing_installs(tmp_path):
    result, calls = deploy(tmp_path, ioreg_script="#!/bin/bash\nexit 1\n")
    assert result.returncode == 69, result.stdout + result.stderr
    assert "cannot read screen-lock state; build not started" in result.stderr
    assert not calls.exists()


LOCKED_DESTINATION = (
    "xcodebuild: error: Timed out waiting for all destinations matching the provided destination specifier to "
    "become available\n\t{ platform:iOS, arch:arm64, id:hardware-id, name:Test Phone, error:The device needs to be "
    "unlocked to continue Unlock the device, then ensure it is discoverable via Bluetooth/WiFi or attached with a "
    "cable. }")


def test_a_destination_locked_at_build_time_names_the_device_not_a_build_failure(tmp_path):
    result, calls = deploy(tmp_path, xcodebuild_fail=LOCKED_DESTINATION)
    assert result.returncode == 79, result.stdout + result.stderr
    assert "test-phone is locked: unlock it and deploy again" in result.stderr
    assert "build failed" not in result.stderr
    assert not calls.exists()


def test_other_build_errors_still_read_as_build_failures(tmp_path):
    result, calls = deploy(tmp_path, xcodebuild_fail="error: compile failed")
    assert result.returncode == 70, result.stdout + result.stderr
    assert "build failed: nothing installed" in result.stderr
    assert not calls.exists()


def test_a_successful_build_that_mentions_a_locked_device_still_installs(tmp_path):
    result, calls = deploy(tmp_path, xcodebuild_note="warning: another device needs to be unlocked to continue")
    assert result.returncode == 0, result.stdout + result.stderr
    assert "is locked" not in result.stderr
    assert len(calls.read_text().splitlines()) == 2
