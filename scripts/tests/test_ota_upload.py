"""ota-upload.sh with stub ssh and scp: what it publishes, under which name, and when it skips."""

import os
import plistlib
import subprocess
import zipfile
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "ota-upload.sh"
SHA = "89c1cabbf2217ce2abf1c3ff875a985fe502aa0c"


def setup(tmp_path: Path, info: dict, signed: bool = True):
    app = tmp_path / "Demo App.app"
    (app / "Frameworks").mkdir(parents=True)
    (app / "Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": "com.example.demo", **info}))
    (app / "Frameworks" / "link").symlink_to("../Info.plist")
    if signed:
        (app / "embedded.mobileprovision").write_text("profile")
    remote = tmp_path / "remote"
    (remote / "builds").mkdir(parents=True)
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    # ssh … -- host <command>: run it in the fake remote home. scp … -- <src> host:<dest>: copy it there.
    (bin_dir / "ssh").write_text(f'#!/bin/bash\nfor a; do last=$a; done\ncd "{remote}" && bash -c "$last"\n')
    (bin_dir / "scp").write_text(
        f'#!/bin/bash\nn=$#; src=${{@:n-1:1}}; dest=${{@:n:1}}\ncp "$src" "{remote}/${{dest#*:}}"\n'
    )
    for f in ("ssh", "scp"):
        (bin_dir / f).chmod(0o755)
    env = {
        **os.environ,
        "PATH": f"{bin_dir}:{os.environ['PATH']}",
        "OTA_HOST": "builds-host",
        "OTA_DIR": "builds",
        "OTA_UPLOAD_LOG": str(tmp_path / "ota.log"),
        "BUG_KIT_CONFIG": str(tmp_path / "none.json"),
    }
    return app, remote / "builds", env


def run(app, env, *args):
    return subprocess.run([str(SCRIPT), str(app), "--name", "demo", *args], capture_output=True, text=True, env=env)


def test_publishes_the_bundle_named_by_its_commit(tmp_path):
    app, builds, env = setup(tmp_path, {"BugKitCommit": SHA})
    out = run(app, env)
    assert out.returncode == 0, out.stdout + out.stderr
    ipa = builds / "demo-89c1cabb.ipa"
    with zipfile.ZipFile(ipa) as z:
        names = z.namelist()
        assert "Payload/Demo App.app/Info.plist" in names
        assert plistlib.loads(z.read("Payload/Demo App.app/Info.plist"))["BugKitCommit"] == SHA
    assert not [p for p in builds.iterdir() if p.name.endswith(".part")]
    assert "demo-89c1cabb.ipa ->" in (tmp_path / "ota.log").read_text()


def test_an_existing_build_is_touched_not_copied_again(tmp_path):
    app, builds, env = setup(tmp_path, {"GitSha": SHA[:8]})
    (builds / "demo-89c1cabb.ipa").write_text("earlier")
    os.utime(builds / "demo-89c1cabb.ipa", (1, 1))
    out = run(app, env)
    assert out.returncode == 0, out.stderr
    assert (builds / "demo-89c1cabb.ipa").read_text() == "earlier"
    assert (builds / "demo-89c1cabb.ipa").stat().st_mtime > 1
    assert "already on" in out.stdout


def test_a_dirty_build_never_takes_the_clean_name(tmp_path):
    app, builds, env = setup(tmp_path, {"BugKitCommit": "89c1cab-dirty"})
    out = run(app, env)
    assert out.returncode == 0, out.stderr
    assert [p.name for p in builds.iterdir()] == ["demo-89c1cab-dirty.ipa"]


def test_nowhere_configured_publishes_nothing_and_succeeds(tmp_path):
    app, builds, env = setup(tmp_path, {"BugKitCommit": SHA})
    del env["OTA_HOST"], env["OTA_DIR"]
    out = run(app, env)
    assert out.returncode == 0
    assert "nothing published" in out.stdout
    assert not list(builds.iterdir())


def test_a_simulator_build_is_refused(tmp_path):
    app, builds, env = setup(tmp_path, {"BugKitCommit": SHA}, signed=False)
    out = run(app, env)
    assert out.returncode == 66
    assert not list(builds.iterdir())


def test_no_commit_and_no_repo_is_refused(tmp_path):
    app, builds, env = setup(tmp_path, {})
    out = run(app, env)
    assert out.returncode == 66
    assert not list(builds.iterdir())


def make_repo(tmp_path: Path, dirty: bool) -> tuple[Path, str]:
    repo = tmp_path / "repo"
    repo.mkdir()
    git = ["git", "-C", str(repo), "-c", "user.name=t", "-c", "user.email=test@localhost"]
    subprocess.run([*git, "init", "-q"], check=True)
    (repo / "a.txt").write_text("a\n")
    subprocess.run([*git, "add", "a.txt"], check=True)
    subprocess.run([*git, "commit", "-q", "-m", "one"], check=True)
    if dirty:
        (repo / "a.txt").write_text("b\n")
    head = subprocess.run([*git, "rev-parse", "HEAD"], capture_output=True, text=True, check=True).stdout.strip()
    return repo, head


def test_a_gitsha_build_from_a_dirty_checkout_never_takes_the_clean_name(tmp_path):
    repo, head = make_repo(tmp_path, dirty=True)
    app, builds, env = setup(tmp_path, {"GitSha": head[:7]})
    (builds / f"demo-{head[:8]}.ipa").write_text("clean")
    out = run(app, env, "--repo", str(repo))
    assert out.returncode == 0, out.stdout + out.stderr
    assert (builds / f"demo-{head[:8]}-dirty.ipa").exists()
    assert (builds / f"demo-{head[:8]}.ipa").read_text() == "clean"


def test_a_gitsha_build_from_a_clean_checkout_takes_the_clean_name(tmp_path):
    repo, head = make_repo(tmp_path, dirty=False)
    app, builds, env = setup(tmp_path, {"GitSha": head[:7]})
    out = run(app, env, "--repo", str(repo))
    assert out.returncode == 0, out.stdout + out.stderr
    assert [p.name for p in builds.iterdir()] == [f"demo-{head[:8]}.ipa"]


def test_a_home_relative_dir_is_the_login_home(tmp_path):
    app, builds, env = setup(tmp_path, {"BugKitCommit": SHA})
    (builds / "demo-89c1cabb.ipa").write_text("earlier")
    out = run(app, {**env, "OTA_DIR": "~/builds"})
    assert out.returncode == 0, out.stdout + out.stderr
    assert "already on" in out.stdout
    assert [p.name for p in builds.iterdir()] == ["demo-89c1cabb.ipa"]


def test_an_option_missing_its_value_is_a_usage_error(tmp_path):
    app, _, env = setup(tmp_path, {"BugKitCommit": SHA})
    for opt in ("--name", "--repo"):
        out = subprocess.run([str(SCRIPT), str(app), opt], capture_output=True, text=True, env=env, timeout=10)
        assert out.returncode == 64


def test_nowhere_configured_is_logged(tmp_path):
    app, _, env = setup(tmp_path, {"BugKitCommit": SHA})
    del env["OTA_HOST"], env["OTA_DIR"]
    out = run(app, env)
    assert out.returncode == 0
    assert "nothing published" in (tmp_path / "ota.log").read_text()
