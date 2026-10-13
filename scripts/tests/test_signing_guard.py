"""Host-only signing checks: every OS/build command is fake; no signing or display changes."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys

import pytest

ROOT = Path(__file__).resolve().parents[2]
GUARD = ROOT / "scripts/signing-guard.sh"


def tool(folder, name, body):
    path = folder / name
    path.write_text(f"#!{sys.executable}\n" + body)
    path.chmod(0o755)
    return path


def fake_tools(tmp_path, states):
    folder = tmp_path / "bin"
    folder.mkdir()
    state = tmp_path / "states.json"
    state.write_text(json.dumps(states))
    env = {**os.environ, "PATH": f"{folder}:{os.environ['PATH']}",
           "GUARD_TEST_ROOT": str(tmp_path)}
    tool(folder, "ioreg", '''import json, os, pathlib, sys
root = pathlib.Path(os.environ['GUARD_TEST_ROOT'])
assert sys.argv[1:] == ['-n', 'Root', '-d1']
states = json.loads((root / 'states.json').read_text())
current = states.pop(0) if len(states) > 1 else states[0]
(root / 'states.json').write_text(json.dumps(states))
if current == 'error': sys.exit(1)
print(current)
''')
    tool(folder, "caffeinate", '''import json, os, pathlib, signal, sys
root = pathlib.Path(os.environ['GUARD_TEST_ROOT'])
(root / 'caffeinate.json').write_text(json.dumps({'args': sys.argv[1:], 'pid': os.getpid()}))
signal.pause()
''')
    tool(folder, "sleep", '''import os, pathlib, sys
assert sys.argv[1:] == ['5']
root = pathlib.Path(os.environ['GUARD_TEST_ROOT'])
with (root / 'waited').open('a') as f: f.write('wait\\n')
''')
    tool(folder, "fake-build", '''import json, os, pathlib, sys, time
root = pathlib.Path(os.environ['GUARD_TEST_ROOT'])
for _ in range(100):
    if (root / 'caffeinate.json').exists(): break
    time.sleep(.01)
with (root / 'builds.jsonl').open('a') as f: f.write(json.dumps(sys.argv[1:]) + '\\n')
print(os.environ.get('GUARD_TEST_OUTPUT', '** BUILD SUCCEEDED **'))
sys.exit(int(os.environ.get('GUARD_TEST_EXIT', '0')))
''')
    return env


def guarded(env, *args):
    return subprocess.run([str(GUARD), "fake-build", *args], env=env,
                          capture_output=True, text=True, timeout=10)


def test_locked_mac_waits_until_unlock_then_builds_once_with_display_assertion(tmp_path):
    env = fake_tools(tmp_path, ['"CGSSessionScreenIsLocked"=Yes',
                               '"CGSSessionScreenIsLocked" = Yes',
                               '"CGSSessionScreenIsLocked" = No'])
    result = guarded(env, "path with spaces", "-allowProvisioningUpdates")
    assert result.returncode == 0, result.stderr
    assert (tmp_path / "waited").read_text().splitlines() == ["wait", "wait"]
    assert [json.loads(x) for x in (tmp_path / "builds.jsonl").read_text().splitlines()] == [
        ["path with spaces", "-allowProvisioningUpdates"]]
    assertion = json.loads((tmp_path / "caffeinate.json").read_text())
    assert assertion["args"][0:2] == ["-d", "-w"]
    assert assertion["args"][2].isdigit()
    with pytest.raises(ProcessLookupError):
        os.kill(assertion["pid"], 0)  # guard must release and reap its helper
    assert "waiting" in result.stderr and "Mac unlocked" in result.stderr


@pytest.mark.parametrize("state", ['"CGSSessionScreenIsLocked" = No', '+-o Root <class IORegistryEntry>'])
def test_unlocked_or_absent_lock_flag_builds_without_waiting(tmp_path, state):
    env = fake_tools(tmp_path, [state])
    result = guarded(env)
    assert result.returncode == 0, result.stderr
    assert not (tmp_path / "waited").exists()
    assert (tmp_path / "builds.jsonl").exists()


@pytest.mark.parametrize("state", ["error", ""])
def test_unreadable_lock_state_never_starts_build(tmp_path, state):
    env = fake_tools(tmp_path, [state])
    result = guarded(env)
    assert result.returncode == 69
    assert "build not started" in result.stderr
    assert not (tmp_path / "builds.jsonl").exists()


@pytest.mark.parametrize("message", ["error: No Accounts: Add a new account",
                                    "DVTDeveloperAccountManager:critical Failed to load credentials"])
@pytest.mark.parametrize("status", [0, 65])
def test_account_loss_is_fatal_even_after_success_and_never_retried(tmp_path, message, status):
    env = fake_tools(tmp_path, ['"CGSSessionScreenIsLocked" = No'])
    env.update(GUARD_TEST_OUTPUT=message + "\n** BUILD SUCCEEDED **", GUARD_TEST_EXIT=str(status))
    result = guarded(env)
    assert result.returncode == 78
    assert "do not retry or install" in result.stderr
    assert len((tmp_path / "builds.jsonl").read_text().splitlines()) == 1


def test_other_build_failure_preserves_exit_status(tmp_path):
    env = fake_tools(tmp_path, ['"CGSSessionScreenIsLocked" = No'])
    env.update(GUARD_TEST_OUTPUT="error: compile failed", GUARD_TEST_EXIT="65")
    result = guarded(env)
    assert result.returncode == 65
    assert "account access failed" not in result.stderr


@pytest.mark.parametrize("unsigned", [False, True])
def test_reader_signed_path_wraps_guard_inside_lock_and_stops_before_install(tmp_path, monkeypatch, unsigned):
    spec = importlib.util.spec_from_file_location("guarded_reader_build", ROOT / "scripts/build-cloudkit-reader.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    fake_root = tmp_path / "repo"
    monkeypatch.setattr(module, "__file__", str(fake_root / "scripts/build-cloudkit-reader.py"))
    # Keep all generated files and lock-directory setup in this test's private fixture.
    monkeypatch.setattr(module.Path, "home", classmethod(lambda cls: tmp_path))
    config = tmp_path / "config.json"
    destination = tmp_path / "Reader.app"
    config.write_text(json.dumps({"team": "YOURTEAMID", "bundle": "com.example.Reader",
                                  "container": "iCloud.com.example.Reports", "environment": "Development",
                                  "app": str(destination)}))
    monkeypatch.setattr(sys, "argv", ["reader", "--config", str(config)] + (["--unsigned"] if unsigned else []))
    calls = []

    def fake_run(args, **kwargs):
        calls.append(args)
        return subprocess.CompletedProcess(args, 0 if args[0] == "xcodegen" else 78)

    monkeypatch.setattr(module.subprocess, "run", fake_run)
    assert module.main() == 78
    build = calls[1]
    if unsigned:
        assert build[0] == "xcodebuild" and "CODE_SIGNING_ALLOWED=NO" in build
        assert not any("signing-guard" in arg for arg in build)
    else:
        assert build[:4] == ["lockf", "-k", "-t", "900"]
        assert build[5:7] == [str(fake_root / "scripts/signing-guard.sh"), "xcodebuild"]
    assert len(calls) == 2
    assert not destination.exists()
