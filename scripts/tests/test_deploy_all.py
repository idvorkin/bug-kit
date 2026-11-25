"""deploy-all.sh --dry-run with a stub xcrun: the build settings it would pass."""

import json
import os
import subprocess
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "deploy-all.sh"

DEVICES = {
    "result": {
        "devices": [
            {
                "identifier": "core-1",
                "hardwareProperties": {
                    "reality": "physical",
                    "udid": "hw-1",
                    "deviceType": "iPhone",
                    "marketingName": "iPhone 17 Pro",
                },
            }
        ]
    }
}


def setup(tmp_path: Path, dirty: bool):
    repo = tmp_path / "repo"
    repo.mkdir()
    git = ["git", "-C", str(repo), "-c", "user.name=t", "-c", "user.email=test@localhost"]
    subprocess.run([*git[:3], "init", "-q"], check=True)
    (repo / "a.txt").write_text("a\n")
    subprocess.run([*git, "add", "a.txt"], check=True)
    subprocess.run([*git, "commit", "-q", "-m", "one"], check=True)
    subprocess.run([*git, "tag", "v1"], check=True)  # a tag must not leak into {describe}
    if dirty:
        (repo / "a.txt").write_text("b\n")
    sha = subprocess.run([*git[:3], "rev-parse", "--short", "HEAD"], capture_output=True, text=True).stdout.strip()

    config = tmp_path / "apps.json"
    config.write_text(
        json.dumps(
            {
                "apps": [
                    {
                        "name": "demo",
                        "bundle": "com.example.demo",
                        "repo": str(repo),
                        "build": {
                            "scheme": "Demo",
                            "project": "Demo.xcodeproj",
                            "app": "Build/Demo.app",
                            "settings": ["BUGKIT_COMMIT={describe}", "GIT_SHA={sha}"],
                        },
                    }
                ]
            }
        )
    )
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    (tmp_path / "devices.json").write_text(json.dumps(DEVICES))
    stub = bin_dir / "xcrun"
    # `xcrun devicectl list devices --json-output <file>`: copy the canned list there.
    stub.write_text(f'#!/bin/bash\nfor a; do last=$a; done\ncp "{tmp_path}/devices.json" "$last"\n')
    stub.chmod(0o755)
    env = {**os.environ, "PATH": f"{bin_dir}:{os.environ['PATH']}", "BUG_KIT_CONFIG": str(config)}
    return env, sha


def dry_run(env):
    """The commands it would run are printed on stderr (fd 3), the progress on stdout."""
    out = subprocess.run([str(SCRIPT), "demo", "--dry-run"], capture_output=True, text=True, env=env)
    out.commands = out.stderr
    return out


def test_describe_is_the_short_commit(tmp_path):
    env, sha = setup(tmp_path, dirty=False)
    out = dry_run(env)
    assert out.returncode == 0, out.stderr
    assert f"BUGKIT_COMMIT={sha} " in out.commands
    assert f"GIT_SHA={sha} " in out.commands
    assert "v1" not in out.commands


def test_describe_says_dirty_for_uncommitted_changes(tmp_path):
    env, sha = setup(tmp_path, dirty=True)
    out = dry_run(env)
    assert out.returncode == 0, out.stderr
    assert f"BUGKIT_COMMIT={sha}-dirty " in out.commands


def test_the_installed_bundle_goes_over_the_air_under_its_ota_name(tmp_path):
    env, _ = setup(tmp_path, dirty=False)
    out = dry_run(env)
    assert out.returncode == 0, out.stderr
    assert "ota-upload.sh " in out.commands and "/Build/Demo.app --name demo --repo " in out.commands


def test_ota_upload_off_leaves_it_out(tmp_path):
    env, _ = setup(tmp_path, dirty=False)
    out = dry_run({**env, "OTA_UPLOAD": "0"})
    assert out.returncode == 0, out.stderr
    assert "ota-upload.sh" not in out.commands


def uploader_args(commands: str) -> list[str]:
    line = next(l for l in commands.splitlines() if "ota-upload.sh" in l)
    return line.split()


def test_started_by_a_relative_path_it_still_finds_the_uploader(tmp_path):
    env, _ = setup(tmp_path, dirty=False)
    root = SCRIPT.parents[1]
    out = subprocess.run(
        ["scripts/deploy-all.sh", "demo", "--dry-run"], capture_output=True, text=True, env=env, cwd=root
    )
    assert out.returncode == 0, out.stderr
    uploader = next(a for a in uploader_args(out.stderr) if a.endswith("ota-upload.sh"))
    assert Path(uploader).resolve() == SCRIPT.parent / "ota-upload.sh"


def test_the_uploader_is_told_whether_the_build_was_dirty(tmp_path):
    for dirty, flag in ((False, "0"), (True, "1")):
        (tmp_path / flag).mkdir()
        env, _ = setup(tmp_path / flag, dirty=dirty)
        args = uploader_args(dry_run(env).commands)
        assert args[args.index("--built-dirty") + 1] == flag
