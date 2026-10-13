"""Host tests for bug-listener's pure parts: uv run --with typer --with pytest pytest listener/"""

import importlib.machinery
import importlib.util
import json
import uuid
from pathlib import Path

import pytest

HERE = Path(__file__).parent
loader = importlib.machinery.SourceFileLoader("bug_listener", str(HERE / "bug-listener"))
spec = importlib.util.spec_from_loader("bug_listener", loader)
bl = importlib.util.module_from_spec(spec)
loader.exec_module(bl)


def cloud_fixture(tmp_path):
    inbox = tmp_path / "cloud"
    identity = str(uuid.uuid4()).upper()
    folder = inbox / identity
    documents = folder / "Documents"
    evidence = documents / "bugs" / "sample" / "screen.png"
    evidence.parent.mkdir(parents=True)
    evidence.write_bytes(b"synthetic screen")
    rec = {"id": identity, "bundle": "local.fixture", "app": "fixture", "note": "fixture note",
           "reported_at": "2026-10-11T00:00:00Z", "folder": "bugs/sample", "files": [],
           "screenshot": "bugs/sample/screen.png", "device": "synthetic"}
    (folder / "report.json").write_text(json.dumps(rec))
    (folder / "files.json").write_text(json.dumps({rec["screenshot"]: len(b"synthetic screen")}))
    a = {"name": "fixture", "bundle": "local.fixture", "tracker": {"kind": "none"}}
    cloud = {"app": "/synthetic/BugKitCloudReader.app", "container": "iCloud.com.example.BugKitReports",
             "inbox": str(inbox), "environment": "Development"}
    cfg = {"apps": [a], "poll_seconds": 300, "cloudkit": cloud}
    return cfg, rec, evidence


def synced(*events):
    output = "\n".join(json.dumps(e) for e in (*events, {"event": "cloudkit_sync", "ok": True}))
    return lambda *args, **kwargs: (0, output, "")


class CloudFakeFiler:
    def __init__(self):
        self.calls = []

    def check(self, a, rec):
        return None

    def file(self, a, rec, key, dev, local):
        self.calls.append((key, local))
        return "filed", "synthetic-ref"


def cloud_summary():
    return {"reachable": 0, "new": 0, "filed": 0, "would_file": 0, "errors": 0, "skipped": 0}


def test_cloud_reports_file_once_and_dedupe_later_device_delivery(listener_state):
    cfg, rec, evidence = cloud_fixture(listener_state)
    filer = CloudFakeFiler()
    seen = {}
    summary = cloud_summary()
    bl.poll_cloud_reports(cfg, seen, filer, summary, False)
    bl.poll_cloud_reports(cfg, seen, filer, summary, False)
    assert len(filer.calls) == 1
    assert (filer.calls[0][1] / rec["screenshot"]).read_bytes() == b"synthetic screen"
    # Actual cloud intake must count as delivery across the device lane, even for Beads/inbox trackers.
    entry = {"keys": []}
    assert bl.already_filed(filer, cfg["apps"][0], rec, {"dir": "phone"}, entry, "keys", seen, summary)
    assert entry["keys"] == [rec["id"]]
    assert len(filer.calls) == 1


def test_cloud_reports_dedupe_previous_device_delivery(listener_state):
    cfg, rec, _ = cloud_fixture(listener_state)
    filer = CloudFakeFiler()
    seen = {"_deliveries": {rec["bundle"] + ":" + rec["id"]: {"ref": "device-ref"}}}
    summary = cloud_summary()
    bl.poll_cloud_reports(cfg, seen, filer, summary, False)
    assert not filer.calls
    assert summary["skipped"] == 1


def test_cloud_missing_or_truncated_evidence_stays_pending_then_retries(listener_state):
    cfg, rec, evidence = cloud_fixture(listener_state)
    evidence.write_bytes(b"cut")
    filer, seen, summary = CloudFakeFiler(), {}, cloud_summary()
    bl.poll_cloud_reports(cfg, seen, filer, summary, False)
    entry = seen[rec["bundle"] + "|cloudkit"]
    assert entry["keys"] == [] and rec["id"] in entry["pending"]
    assert summary["errors"] == 1 and not filer.calls
    evidence.write_bytes(b"synthetic screen")
    bl.poll_cloud_reports(cfg, seen, filer, summary, False)
    assert len(filer.calls) == 1 and not entry["pending"]


def test_cloud_payload_path_escape_is_rejected(listener_state):
    cfg, rec, _ = cloud_fixture(listener_state)
    folder = Path(cfg["cloudkit"]["inbox"]) / rec["id"]
    rec["screenshot"] = "../outside.png"
    (folder / "report.json").write_text(json.dumps(rec))
    (folder / "files.json").write_text(json.dumps({rec["screenshot"]: 1}))
    (folder / "outside.png").write_bytes(b"x")
    filer, summary = CloudFakeFiler(), cloud_summary()
    bl.poll_cloud_reports(cfg, {}, filer, summary, False)
    assert not filer.calls and summary["errors"] == 1


def test_cloud_poll_delivers_with_no_paired_devices(listener_state, monkeypatch):
    cfg, _, _ = cloud_fixture(listener_state)
    monkeypatch.setattr(bl, "run", synced())
    monkeypatch.setattr(bl, "list_devices", lambda: [])
    monkeypatch.setattr(bl, "Filer", CloudFakeFiler)
    summary = bl.poll(cfg, False)
    assert summary["devices"] == 0 and summary["filed"] == 1 and summary["reachable"] == 1
    assert summary["errors"] == 0


def test_cloud_dry_run_retains_delivery_state(listener_state, monkeypatch):
    cfg, _, _ = cloud_fixture(listener_state)
    monkeypatch.setattr(bl, "DRY", True)
    bl.poll_cloud_reports(cfg, {}, bl.Filer(), cloud_summary(), False)
    assert not bl.SEEN.exists() and not bl.INBOX.exists()


def test_doctor_checks_reader_signing_without_contacting_cloudkit(listener_state, monkeypatch):
    cloud = listener_state / "cloudkit.json"
    cloud.write_text(json.dumps({"container": "iCloud.com.example.BugKitReports", "environment": "Production",
                                 "app": str(listener_state / "reader.app"), "inbox": str(listener_state / "downloads")}))
    config = listener_state / "apps.json"
    config.write_text(json.dumps({"apps": [{"name": "fixture", "bundle": "local.fixture"}],
                                  "cloudkit_config": str(cloud)}))
    calls = []
    monkeypatch.setattr(bl.shutil, "which", lambda _: None)
    monkeypatch.setattr(bl, "run", lambda cmd, **kwargs: (calls.append(cmd), (0, "", ""))[1])
    checks = {c["check"]: c["state"] for c in bl.doctor_checks(config)["checks"]}
    assert checks["cloudkit_signing"] == "ok" and checks["devicectl"] == "error"
    assert calls == [[str(listener_state / "reader.app/Contents/MacOS/BugKitCloudReader"), "--check-signing",
                      "--container", "iCloud.com.example.BugKitReports", "--environment", "Production"]]


@pytest.mark.parametrize("group, domain, identifier", [
    (None, "appDataContainer", "local.fixture"),
    ("group.local.fixture", "appGroupDataContainer", "group.local.fixture"),
])
def test_copy_uses_configured_container_domain(listener_state, monkeypatch, group, domain, identifier):
    calls = []
    destination = listener_state / "copied" / "bugs.jsonl"
    def fake_run(cmd, **kwargs):
        calls.append(cmd)
        destination.write_text('{"id":"fixture"}\n')
        return 0, "", ""
    monkeypatch.setattr(bl, "run", fake_run)
    a = {"name": "fixture", "bundle": "local.fixture"}
    if group:
        a["app_group"] = group
    assert bl.copy({"id": "fake-device", "dir": "fixture"}, a, "Documents/bugs.jsonl", destination, False)
    cmd = calls[0]
    assert cmd[cmd.index("--domain-type") + 1] == domain
    assert cmd[cmd.index("--domain-identifier") + 1] == identifier
    assert cmd[cmd.index("--source") + 1] == "Documents/bugs.jsonl"
    assert json.loads((listener_state / "listener.log").read_text())["domain"] == domain


@pytest.mark.parametrize("group", ["", "not-a-group", "group.bad/path", 7, None])
def test_config_rejects_invalid_app_group(tmp_path, group):
    config = tmp_path / "apps.json"
    config.write_text(json.dumps({"apps": [{"name": "fixture", "bundle": "local.fixture", "app_group": group}]}))
    with pytest.raises(ValueError, match="app_group"):
        bl.load_config(config)


def test_index_tolerates_broken_lines_and_keeps_u2028(tmp_path, monkeypatch):
    monkeypatch.setattr(bl, "STATE", tmp_path)
    monkeypatch.setattr(bl, "LOG", tmp_path / "listener.log")
    good = {"id": "A", "reported_at": "2026-10-10T00:00:00Z", "note": "line sep and \u0085 too"}
    old = {"reported_at": "2026-10-08T04:00:18Z", "note": "fine"}
    # An older app's note with a raw newline: two fragments, neither valid JSON.
    broken = '{"reported_at":"2026-10-09T00:00:00Z","note":"first half\nsecond half"}'
    index = tmp_path / "bugs.jsonl"
    index.write_text(json.dumps(good, ensure_ascii=False) + "\n" + broken + "\n" + json.dumps(old) + "\n\n")
    reports = bl.read_index(index, {"device": "d", "app": "a"})
    assert [k for k, _ in reports] == ["A", "2026-10-08T04:00:18Z"]
    assert reports[0][1]["note"] == good["note"]
    logged = [json.loads(l) for l in (tmp_path / "listener.log").read_text().splitlines()]
    assert [e["event"] for e in logged] == ["line_unreadable", "line_unreadable"]
    assert logged[0]["line"] == 2 and logged[1]["line"] == 3


def test_issue_body_names_the_screenshot_and_carries_both_markers(tmp_path):
    rec = {"id": "X1", "reported_at": "2026-10-10T00:00:00.000Z", "note": "a | b\nc", "screen": "home",
           "screenshot": "bugs/s/screen.png", "log": "logs/app-1.jsonl", "session_t_ms": 5, "context": {"k": 1}}
    dev = {"type": "iPhone", "model": "iPhone 17 Pro", "dir": "iphone-17-pro"}
    body = bl.issue_body(rec, "X1", dev, {"name": "app"}, tmp_path)
    assert "<!-- bug:2026-10-10T00:00:00.000Z -->" in body and "<!-- bug-id:X1 -->" in body
    assert "not uploaded" in body and "![" not in body
    assert "| k | 1 |" in body


def test_titles_skip_blank_lines_and_bullets():
    assert bl.title_of({"note": "\n\n- the timer skipped"}) == "the timer skipped"
    assert bl.title_of({"note": "", "reported_at": "T"}) == "Report from the device, T"


def test_report_keys_fall_back_to_reported_at():
    assert bl.report_key({"id": "U"}, "x") == "U"
    assert bl.report_key({"reported_at": "T"}, "x") == "T"
    assert bl.report_key({}, "x").startswith("sha1:")


@pytest.fixture
def listener_state(tmp_path, monkeypatch):
    for name, value in {"STATE": tmp_path, "LOG": tmp_path / "listener.log",
                        "SEEN": tmp_path / "seen.json", "INBOX": tmp_path / "inbox.jsonl", "DRY": False}.items():
        monkeypatch.setattr(bl, name, value)
    monkeypatch.setattr(bl, "notify", lambda *args: None)
    return tmp_path


@pytest.mark.parametrize("existing", [
    "<!-- bug:T -->\n<!-- bug-id:A -->",
    "<!-- bug:T -->\n<!-- bug-id:A -->\nThe same problem occurs after opening the settings screen",
])
def test_distinct_ids_are_not_deduped_by_timestamp_or_note(listener_state, monkeypatch, existing):
    monkeypatch.setattr(bl, "run", lambda *args, **kwargs: (0, json.dumps([{"body": existing}]), ""))
    rec = {"id": "B", "reported_at": "T", "note": "The same problem occurs after opening the settings screen"}
    assert bl.Filer().check({"tracker": {"kind": "github", "repo": "owner/app"}}, rec) is None


@pytest.mark.parametrize("body", ["<!-- bug:T -->", "<!-- bug:T -->\n<!-- bug-id:A -->"])
def test_existing_legacy_and_uuid_markers_are_respected(listener_state, monkeypatch, body):
    monkeypatch.setattr(bl, "run", lambda *args, **kwargs: (0, json.dumps([{"body": body}]), ""))
    assert bl.Filer().check({"tracker": {"kind": "github", "repo": "owner/app"}},
                           {"id": "A", "reported_at": "T"})[0] == "already_filed"


def test_marker_free_issues_still_match_the_note(listener_state, monkeypatch):
    note = "The timer stopped updating when I opened the settings screen"
    monkeypatch.setattr(bl, "run", lambda *args, **kwargs: (0, json.dumps([{"body": f"> {note}"}]), ""))
    assert bl.Filer().check({"tracker": {"kind": "github", "repo": "owner/app"}},
                           {"id": "A", "note": note})[0] == "already_filed"


@pytest.mark.parametrize("response", ["not JSON", "{}", '[{"body": 7}]'])
def test_invalid_issue_lookup_stops_filing(listener_state, monkeypatch, response):
    monkeypatch.setattr(bl, "run", lambda *args, **kwargs: (0, response, ""))
    assert bl.Filer().check({"tracker": {"kind": "github", "repo": "owner/app"}},
                           {"id": "A", "note": "A note"}) == ("error", None)


def test_a_created_issue_is_cached_by_id_without_a_timestamp(listener_state, monkeypatch):
    responses = iter([(0, "[]", ""), (0, "https://github.com/owner/app/issues/1\n", "")])
    monkeypatch.setattr(bl, "run", lambda *args, **kwargs: next(responses))
    filer = bl.Filer()
    a = {"name": "app", "tracker": {"kind": "github", "repo": "owner/app"}}
    rec = {"id": "A", "note": "A short note"}
    assert filer.check(a, rec) is None
    assert filer.file(a, rec, "A", {"type": "iPhone", "model": "phone"}, listener_state)[0] == "filed"
    assert filer.check(a, rec)[0] == "already_filed"


@pytest.mark.parametrize("failed_source", ["Documents/bugs/s", "Documents/logs/session.jsonl", None])
def test_poll_retries_required_evidence_and_files_duplicate_lines_once(listener_state, monkeypatch, failed_source):
    dev = {"id": "device-id", "dir": "iphone", "type": "iPhone", "model": "phone"}
    a = {"name": "app", "bundle": "app.bundle", "tracker": {"kind": "none"}, "crash_dir": "Documents/crashes"}
    rec = {"id": "A", "note": "A short note", "folder": "bugs/s", "log": "logs/session.jsonl"}
    monkeypatch.setattr(bl, "list_devices", lambda: [dev])
    monkeypatch.setattr(bl, "probe", lambda dev: {"locked": True})

    def copy(dev, a, source, dest, locked, **kwargs):
        dest.parent.mkdir(parents=True, exist_ok=True)
        if source == "Documents/bugs.jsonl":
            dest.write_text((json.dumps(rec) + "\n") * 2)
        # Crashes may never have occurred, so this missing directory must not block a report.
        return source != failed_source

    monkeypatch.setattr(bl, "copy", copy)
    summary = bl.poll({"apps": [a]}, backfill=True)
    keys = bl.load_seen()["app.bundle|device-id"]["keys"]
    if failed_source:
        assert keys == []
        assert summary["errors"] >= 1
        assert not bl.INBOX.exists()
        # The next poll succeeds and must deliver exactly one report.
        failed_source = None
        bl.poll({"apps": [a]}, backfill=False)
    assert bl.load_seen()["app.bundle|device-id"]["keys"] == ["A"]
    assert len(bl.INBOX.read_text().splitlines()) == 1


@pytest.fixture
def crash_device(listener_state, monkeypatch):
    dev = {"id": "device-id", "dir": "iphone", "type": "iPhone", "model": "phone", "pairing": "paired"}
    app = {"name": "app", "bundle": "app.bundle", "tracker": {"kind": "none"}}
    files = {}
    failures = set()
    monkeypatch.setattr(bl, "list_devices", lambda: [dev])
    monkeypatch.setattr(bl, "probe", lambda dev: {"locked": True})
    def copy(dev, a, source, dest, locked, **kwargs):
        if source in failures:
            return False
        if source == "Documents/crashes":
            dest.mkdir(parents=True, exist_ok=True)
            for name, content in files.items():
                (dest / name).write_text(content)
        elif source == "Documents/logs":
            dest.mkdir(parents=True, exist_ok=True)
            (dest / "previous.jsonl").write_text(json.dumps({
                "type": "session_start", "started": "2026-10-10T00:00:00Z", "build": "1 (2)"}) + "\n")
            (dest / "relaunch.jsonl").write_text(json.dumps({
                "type": "session_start", "started": "2026-10-10T01:00:00Z"}) + "\n")
        return True  # No bug index: crashes must still be discovered.
    monkeypatch.setattr(bl, "copy", copy)
    return {"apps": [app], "poll_seconds": 300}, files, failures


def test_crash_discovery_without_manual_reports_and_rename_dedup(crash_device, listener_state):
    cfg, files, _ = crash_device
    epoch = int(bl.parse_time("2026-10-10T00:01:00Z").timestamp())
    bl.poll(cfg, backfill=False)  # successful empty baseline
    files[f"signal-{epoch}.txt"] = "signal 11\nframe 0\n"
    summary = bl.poll(cfg, backfill=False)
    assert summary["crashes"] == 1
    assert len(bl.INBOX.read_text().splitlines()) == 1
    key = json.loads(bl.INBOX.read_text())["key"]
    files[f"signal-{epoch}.reported.txt"] = files.pop(f"signal-{epoch}.txt")
    bl.poll(cfg, backfill=False)
    assert len(bl.INBOX.read_text().splitlines()) == 1
    assert bl.load_seen()["app.bundle|device-id"]["crash_keys"] == [key]
    assert (listener_state / "app/iphone/crashes" / f"signal-{epoch}.txt").exists()
    metadata = json.loads((listener_state / "app/iphone/crashes" / f"signal-{epoch}.txt.report.json").read_text())
    assert metadata["id"] == key
    assert metadata["log"] == "logs/previous.jsonl"


def test_crashes_baseline_separately_from_older_manual_state(crash_device, listener_state):
    cfg, files, _ = crash_device
    bl.save_seen({"app.bundle|device-id": {"keys": [], "since": "old"}})
    files["exception-1791590400.txt"] = "exception NSRangeException\n"
    result = bl.poll(cfg, backfill=False)
    assert result["baselined"] == 1
    assert not bl.INBOX.exists()


def test_crash_backfill_retries_after_log_copy_failure(crash_device, listener_state):
    cfg, files, failures = crash_device
    files["signal-1791590400.txt"] = "signal 6\n"
    failures.update({"Documents/logs", "Documents/bugs.jsonl"})
    bl.poll(cfg, backfill=True)
    entry = bl.load_seen()["app.bundle|device-id"]
    assert entry["crash_keys"] == []
    assert next(iter(entry["pending"].values()))["reason"] == "crash_logs"
    assert not bl.INBOX.exists()
    failures.clear()
    bl.poll(cfg, backfill=False)
    assert len(bl.INBOX.read_text().splitlines()) == 1
    assert not bl.load_seen()["app.bundle|device-id"]["pending"]


def test_crash_session_uses_preceding_start_not_relaunch(crash_device, listener_state, monkeypatch):
    cfg, files, _ = crash_device
    epoch = int(bl.parse_time("2026-10-10T00:01:00Z").timestamp())
    files[f"signal-{epoch}.txt"] = "signal 11\n"
    records = []
    monkeypatch.setattr(bl.Filer, "file", lambda self, a, rec, *args: (records.append(rec) or ("none", "inbox-only")))
    bl.poll(cfg, backfill=True)
    assert records[0]["log"] == "logs/previous.jsonl"
    assert records[0]["session_t_ms"] == 60000
    assert records[0]["build"] == "1 (2)"
    assert records[0]["context"]["session_match"].startswith("inferred")


def test_metrickit_hangs_file_without_claiming_delivery_is_crash_time(crash_device, listener_state, monkeypatch):
    cfg, files, _ = crash_device
    files["20261010-020000.json"] = json.dumps({"hangDiagnostics": [{"callStackTree": {}}]})
    records = []
    monkeypatch.setattr(bl.Filer, "file", lambda self, a, rec, *args: (records.append(rec) or ("none", "inbox-only")))
    bl.poll(cfg, backfill=True)
    assert records[0]["context"]["hang_count"] == 1
    assert "log" not in records[0]
    assert records[0]["context"]["time_basis"] == "payload interval end"
    assert records[0]["context"]["session_match"] == "unknown"


def test_dry_run_crashes_leave_delivery_and_health_state_unchanged(crash_device, listener_state, monkeypatch):
    cfg, files, _ = crash_device
    files["signal-1791590400.txt"] = "signal 6\n"
    monkeypatch.setattr(bl, "DRY", True)
    result = bl.poll(cfg, backfill=True)
    assert result["would_file"] == 1
    assert not bl.SEEN.exists() and not bl.INBOX.exists()
    assert not (listener_state / "status.json").exists()


def test_crash_ignores_stale_local_files_after_failed_copy(crash_device, listener_state):
    cfg, files, failures = crash_device
    stale = listener_state / "app/iphone/crashes/signal-1791590400.txt"
    stale.parent.mkdir(parents=True)
    stale.write_text("signal 6\n")
    failures.add("Documents/crashes")
    result = bl.poll(cfg, backfill=True)
    assert result["errors"] == 1
    assert not bl.INBOX.exists()


def test_pending_crash_lookup_retries(crash_device, listener_state, monkeypatch):
    cfg, files, _ = crash_device
    files["signal-1791590400.txt"] = "signal 6\n"
    monkeypatch.setattr(bl.Filer, "check", lambda *args: ("error", None))
    bl.poll(cfg, backfill=True)
    assert next(iter(bl.load_seen()["app.bundle|device-id"]["pending"].values()))["reason"] == "tracker_lookup"
    monkeypatch.setattr(bl.Filer, "check", lambda *args: None)
    bl.poll(cfg, backfill=False)
    assert len(bl.INBOX.read_text().splitlines()) == 1


def test_crash_github_dedupe_never_uses_generic_note(listener_state, monkeypatch):
    note = "Automatic MetricKit diagnostics: 1 crash(es), 0 hang(s)"
    monkeypatch.setattr(bl, "run", lambda *args, **kwargs: (0, json.dumps([{"body": note}]), ""))
    assert bl.Filer().check({"tracker": {"kind": "github", "repo": "owner/app"}},
                           {"id": "crash:new", "kind": "crash", "note": note}) is None


@pytest.fixture
def cli_config(listener_state):
    path = listener_state / "apps.json"
    path.write_text(json.dumps({"apps": [{"name": "app", "bundle": "b", "tracker": {"kind": "none"}}]}))
    return path


def invoke(args):
    from typer.testing import CliRunner
    return CliRunner().invoke(bl.app, args)


def test_old_cli_flags_still_poll(cli_config, monkeypatch):
    calls = []
    monkeypatch.setattr(bl, "poll", lambda cfg, backfill: (calls.append(backfill) or {"errors": 0, "reachable": 1}))
    result = invoke(["--config", str(cli_config), "--once", "--dry-run", "--backfill"])
    assert result.exit_code == 0, result.output
    assert calls == [True]


def test_doctor_json_checks_setup_without_filing(cli_config, monkeypatch):
    monkeypatch.setattr(bl, "poll", lambda *args: pytest.fail("doctor must not poll"))
    monkeypatch.setattr(bl, "list_devices", lambda: [])
    monkeypatch.setattr(bl.shutil, "which", lambda name: f"/fake/{name}")
    monkeypatch.setattr(bl, "run", lambda *args, **kwargs: (0, "", ""))
    result = invoke(["doctor", "--config", str(cli_config), "--json"])
    assert result.exit_code == 0, result.output
    data = json.loads(result.output)
    assert data["ok"]
    assert {c["check"] for c in data["checks"]} >= {"config", "state_directory", "devicectl", "devices", "tracker:app"}
    assert not bl.INBOX.exists() and not bl.SEEN.exists()


def test_doctor_reports_bad_config_and_missing_tools(cli_config, monkeypatch):
    cli_config.write_text('{"apps": [{"name": "../bad", "bundle": "b"}]}')
    monkeypatch.setattr(bl.shutil, "which", lambda name: None)
    result = invoke(["--config", str(cli_config), "doctor", "--json"])
    assert result.exit_code == 1
    data = json.loads(result.output)
    assert not data["ok"]
    assert any(c["check"] == "config" and c["state"] == "error" for c in data["checks"])


def test_status_reads_pending_and_last_success_without_external_calls(cli_config, monkeypatch):
    monkeypatch.setattr(bl, "run", lambda *args, **kwargs: pytest.fail("status must be offline"))
    bl.save_status({"last_poll_completed": bl.now(), "last_successful_poll": bl.now(), "summary": {"reachable": 1, "errors": 0}})
    bl.save_seen({"b|d": {"pending": {"K": {"app": "app", "device": "phone", "key": "K", "reason": "evidence"}}}})
    result = invoke(["status", "--config", str(cli_config), "--json"])
    assert result.exit_code == 1
    data = json.loads(result.output)
    assert not data["stale"] and data["last_successful_poll"]
    assert data["pending"][0]["reason"] == "evidence"


def test_status_distinguishes_healthy_stale_and_never_run(cli_config):
    result = invoke(["status", "--config", str(cli_config), "--json"])
    assert result.exit_code == 1 and json.loads(result.output)["stale"]
    bl.save_status({"last_poll_completed": bl.now(), "summary": {"reachable": 1, "errors": 0}})
    result = invoke(["status", "--config", str(cli_config), "--json"])
    assert result.exit_code == 0 and json.loads(result.output)["ok"]
    bl.save_status({"last_poll_completed": "2000-01-01T00:00:00Z", "summary": {"reachable": 1}})
    result = invoke(["status", "--config", str(cli_config), "--json"])
    assert result.exit_code == 1 and json.loads(result.output)["stale"]


@pytest.mark.parametrize("reachable", [True, False])
def test_offline_paired_device_is_not_a_poll_error(cli_config, monkeypatch, reachable):
    phone = {"id": "phone-id", "dir": "iphone", "type": "iPhone", "model": "phone"}
    ipad = {"id": "ipad-id", "dir": "ipad", "type": "iPad", "model": "tablet"}
    monkeypatch.setattr(bl, "list_devices", lambda: [phone, ipad])
    monkeypatch.setattr(bl, "probe", lambda dev: {"locked": False} if reachable and dev is phone else None)
    monkeypatch.setattr(bl, "copy", lambda *args, **kwargs: True)
    result = invoke(["--config", str(cli_config), "--once"])
    assert result.exit_code == (0 if reachable else 1), result.output
    state = bl.read_status()
    assert state["summary"]["errors"] == 0 and state["summary"]["reachable"] == int(reachable)
    assert [d["reachable"] for d in state["devices"]] == [reachable, False]
    assert ("last_successful_poll" in state) == reachable
    result = invoke(["status", "--config", str(cli_config), "--json"])
    assert result.exit_code == (0 if reachable else 1), result.output
    assert json.loads(result.output)["ok"] == reachable


def test_poll_failure_preserves_last_success_and_records_error(listener_state, monkeypatch):
    bl.save_status({"last_successful_poll": "before"})
    monkeypatch.setattr(bl, "list_devices", lambda: (_ for _ in ()).throw(RuntimeError("device lookup failed")))
    with pytest.raises(RuntimeError):
        bl.poll({"apps": []}, False)
    state = bl.read_status()
    assert state["last_successful_poll"] == "before"
    assert state["last_error"] == "device lookup failed"
    assert not state["in_progress"]


def test_crash_does_not_match_manual_report_at_same_second(listener_state, monkeypatch):
    monkeypatch.setattr(bl, "run", lambda *args, **kwargs: (0, '[{"body":"<!-- bug:T -->"}]', ""))
    rec = {"id": "crash:new", "kind": "crash", "reported_at": "T", "note": "Automatic crash"}
    a = {"name": "app", "tracker": {"kind": "github", "repo": "owner/app"}}
    assert bl.Filer().check(a, rec) is None
    body = bl.issue_body(rec, rec["id"], {"type": "iPhone", "model": "phone"}, a, listener_state)
    assert "<!-- bug:T -->" not in body
    assert "<!-- bug-id:crash:new -->" in body


@pytest.mark.parametrize("rc,err,expected", [(1, "No such file or directory", True),
    (127, "No such file or directory: xcrun", False), (124, "timed out", False), (1, "device unreachable", False)])
def test_optional_copy_distinguishes_missing_evidence_from_tool_failures(listener_state, monkeypatch, rc, err, expected):
    monkeypatch.setattr(bl, "run", lambda *args, **kwargs: (rc, "", err))
    assert bl.copy({"id": "d", "dir": "phone"}, {"bundle": "b", "name": "app"}, "Documents/crashes",
                   listener_state / "copy", False, allow_missing=True) is expected


@pytest.mark.parametrize("rc", [0, 1])
def test_doctor_checks_github_auth_without_creating_issues(cli_config, monkeypatch, rc):
    cli_config.write_text(json.dumps({"apps": [{"name": "app", "bundle": "b",
        "tracker": {"kind": "github", "repo": "owner/app"}}]}))
    commands = []
    monkeypatch.setattr(bl.shutil, "which", lambda name: f"/fake/{name}" if name != "xcrun" else None)
    def run(command, **kwargs):
        commands.append(command)
        return (rc if command[:3] == ["gh", "auth", "status"] else 0), "[]", ""
    monkeypatch.setattr(bl, "run", run)
    data = bl.doctor_checks(cli_config)
    check = next(c for c in data["checks"] if c["check"] == "tracker:app")
    assert check["state"] == ("ok" if rc == 0 else "error")
    assert all("create" not in command for command in commands)
    assert any(command[:3] == ["gh", "auth", "status"] for command in commands)


def test_status_corrupt_state_exits_two(cli_config, listener_state):
    bl.SEEN.write_text("[]")
    result = invoke(["status", "--config", str(cli_config), "--json"])
    assert result.exit_code == 2
    assert not json.loads(result.output)["ok"]


AUTO = {"id": "AUTO1", "reported_at": "2026-10-10T12:00:00.000Z", "source": "auto", "reason": "call_failed",
        "note": "Automatic report: call_failed", "screen": "call", "files": ["bugs/x/call.jsonl"],
        "context": {"calls": 3}}
DEV = {"type": "iPhone", "model": "iPhone 17 Pro", "dir": "iphone-17-pro"}


def test_auto_reports_get_their_own_title_body_and_label(tmp_path):
    assert bl.title_of(AUTO) == "Automatic report: call_failed"
    assert bl.labels_of(AUTO) == ["bug", "auto"]
    assert bl.labels_of({"note": "x"}) == ["bug"]
    body = bl.issue_body(AUTO, "AUTO1", DEV, {"name": "app"}, tmp_path)
    assert body.startswith("**Automatic report from the iPhone**")
    assert "| Reason | call_failed |" in body and "<!-- bug-id:AUTO1 -->" in body
    assert "| source |" not in body  # source and reason are fixed fields, not context


def test_auto_reports_are_filed_with_the_auto_label(tmp_path, monkeypatch, listener_state):
    monkeypatch.setattr(bl, "DRY", False)
    calls = []
    monkeypatch.setattr(bl, "run", lambda cmd, **kw: (calls.append(cmd), (0, "https://example.invalid/1\n", ""))[1])
    app = {"name": "app", "tracker": {"kind": "github", "repo": "owner/app"}}
    assert bl.Filer().file(app, AUTO, "AUTO1", DEV, tmp_path) == ("filed", "https://example.invalid/1")
    cmd = calls[0]
    assert cmd[cmd.index("--title") + 1] == "Automatic report: call_failed"
    assert [cmd[i + 1] for i, a in enumerate(cmd) if a == "--label"] == ["bug", "auto"]


def test_auto_reports_dedupe_by_id_not_by_their_shared_note(monkeypatch):
    filer = bl.Filer()
    filer.filed_markers["owner/app"] = {"<!-- bug-id:AUTO1 -->"}
    filer.bodies["owner/app"] = ["Automatic report: call_failed_while_dialing at the start"]
    app = {"name": "app", "tracker": {"kind": "github", "repo": "owner/app"}}
    assert filer.check(app, AUTO) == ("already_filed", "owner/app")
    second = {**AUTO, "id": "AUTO2", "reason": "call_failed_while_dialing",
              "note": "Automatic report: call_failed_while_dialing"}
    assert filer.check(app, second) is None  # the same note as an earlier auto issue is not a duplicate


def test_auto_report_does_not_match_a_manual_legacy_timestamp(listener_state, monkeypatch):
    body = f"<!-- bug:{AUTO['reported_at']} -->"
    monkeypatch.setattr(bl, "run", lambda *args, **kwargs: (0, json.dumps([{"body": body}]), ""))
    app = {"name": "app", "tracker": {"kind": "github", "repo": "owner/app"}}
    assert bl.Filer().check(app, AUTO) is None


def test_live_cloud_poll_runs_before_broken_device_discovery_and_hands_off_in_one_poll(listener_state, monkeypatch):
    cfg, rec, _ = cloud_fixture(listener_state)
    calls = []
    def native(cmd, **kwargs):
        calls.append(cmd)
        if len(calls) == 1:
            assert not bl.INBOX.exists()
        return 0, json.dumps({"event": "cloudkit_downloaded", "id": rec["id"], "bundle": rec["bundle"]}) + "\n" + json.dumps({"event": "cloudkit_sync", "ok": True, "downloaded": 1}), ""
    def broken_devices():
        assert calls, "device discovery ran before CloudKit"
        raise RuntimeError("offline tool")
    monkeypatch.setattr(bl, "run", native)
    monkeypatch.setattr(bl, "list_devices", broken_devices)
    monkeypatch.setattr(bl, "Filer", CloudFakeFiler)
    summary = bl.poll(cfg, False)
    assert summary["filed"] == 1 and summary["reachable"] == 1
    assert summary["errors"] == 1  # discovery failure does not suppress the actual handoff
    assert json.loads(bl.INBOX.read_text())["key"] == rec["id"]
    assert calls[0][0] == "/synthetic/BugKitCloudReader.app/Contents/MacOS/BugKitCloudReader"
    events = [json.loads(line) for line in bl.LOG.read_text().splitlines()]
    for hop in ("cloudkit_downloaded", "file", "inbox"):
        assert any(e["event"] == hop and e["key"] == rec["id"] for e in events)
    bl.poll(cfg, False)
    assert len(bl.INBOX.read_text().splitlines()) == 1


@pytest.mark.parametrize("rc, output", [(124, ""), (1, '{"event":"cloudkit_sync","ok":false}'), (0, "no completion")])
def test_cloud_sync_failure_never_reports_healthy_even_with_existing_downloads(listener_state, monkeypatch, rc, output):
    cfg, _, _ = cloud_fixture(listener_state)
    monkeypatch.setattr(bl, "run", lambda *args, **kwargs: (rc, output, "private details are not logged"))
    monkeypatch.setattr(bl, "Filer", CloudFakeFiler)
    monkeypatch.setattr(bl, "list_devices", lambda: [])
    summary = bl.poll(cfg, False)
    assert summary["errors"] >= 1 and summary["reachable"] == 0
    assert summary["filed"] == 1  # previously downloaded reports still reach the agent
    assert bl.read_status()["cloudkit"]["ok"] is False
    assert "private details" not in bl.LOG.read_text()


def test_cloud_sync_relays_failed_report_uuid_without_untrusted_text(listener_state, monkeypatch):
    cfg, rec, _ = cloud_fixture(listener_state)
    failed = "a1b2c3d4-0000-4000-8000-000000000001"
    output = "\n".join(json.dumps(e) for e in (
        {"event": "cloudkit_report_pending", "id": failed, "reason": "download or evidence validation failed"},
        {"event": "cloudkit_report_pending", "reason": "listing failed or record metadata is invalid"},
        {"event": "cloudkit_report_pending", "id": "console-test-record\nprivate details", "reason": "private details"},
        {"event": "cloudkit_report_pending", "id": failed, "reason": ["private details"]},
        {"event": "cloudkit_sync", "ok": False, "code": 2}))
    monkeypatch.setattr(bl, "run", lambda *args, **kwargs: (1, output, ""))
    health = {}
    bl.sync_cloudkit(cfg, cloud_summary(), health)
    events = [json.loads(line) for line in bl.LOG.read_text().splitlines()]
    pending = [e for e in events if e["event"] == "cloudkit_report_pending"]
    assert [e["key"] for e in pending] == [failed.upper(), None, None, failed.upper()]
    assert [e["reason"] for e in pending] == ["download or evidence validation failed",
                                              "listing failed or record metadata is invalid", "unknown", "unknown"]
    assert "private details" not in bl.LOG.read_text()
    assert health["cloudkit"]["ok"] is False


def test_cloudkit_config_resolves_private_file_and_dry_run_does_not_launch_it(listener_state, monkeypatch):
    cloud = listener_state / "cloudkit.json"
    cloud.write_text(json.dumps({"container": "iCloud.com.example.BugKitReports", "environment": "Development",
                                "app": str(listener_state / "reader.app"), "inbox": str(listener_state / "downloads")}))
    config = listener_state / "apps.json"
    config.write_text(json.dumps({"apps": [{"name": "fixture", "bundle": "local.fixture"}],
                                  "cloudkit_config": str(cloud)}))
    cfg = bl.load_config(config)
    assert cfg["cloudkit"]["inbox"] == str(listener_state / "downloads")
    monkeypatch.setattr(bl, "DRY", True)
    monkeypatch.setattr(bl, "run", lambda *a, **k: pytest.fail("dry run launched CloudKit"))
    bl.sync_cloudkit(cfg, cloud_summary(), {})


def test_inbox_history_prevents_duplicate_after_seen_store_loss(listener_state):
    cfg, rec, _ = cloud_fixture(listener_state)
    filer = CloudFakeFiler()
    bl.poll_cloud_reports(cfg, {}, filer, cloud_summary(), False)
    bl.SEEN.unlink()
    seen = bl.load_seen()
    bl.poll_cloud_reports(cfg, seen, filer, cloud_summary(), False)
    assert len(filer.calls) == 1
    assert len(bl.INBOX.read_text().splitlines()) == 1


def test_inbox_bundle_receipts_survive_renamed_app_and_seen_store_loss(listener_state):
    cfg, rec, _ = cloud_fixture(listener_state)
    filer = CloudFakeFiler()  # cannot look up an existing issue, like an inbox/Beads tracker
    bl.poll_cloud_reports(cfg, {}, filer, cloud_summary(), False)
    receipt = json.loads(bl.INBOX.read_text())
    assert receipt["bundle"] == rec["bundle"]
    cfg["apps"][0]["name"] = "renamed-fixture"
    bl.SEEN.unlink()
    seen = bl.load_seen()
    summary = cloud_summary()
    bl.poll_cloud_reports(cfg, seen, filer, summary, False)
    assert len(filer.calls) == 1
    assert summary["skipped"] == 1
    assert len(bl.INBOX.read_text().splitlines()) == 1
    # Recovery also dedupes a subsequent device pull under the new display name.
    assert bl.already_filed(filer, cfg["apps"][0], rec, {"dir": "phone"}, {"keys": []},
                            "keys", seen, cloud_summary())


def test_bundle_receipt_does_not_suppress_another_bundle_with_same_display_name(listener_state):
    cfg, rec, _ = cloud_fixture(listener_state)
    bl.INBOX.write_text(json.dumps({"app": "fixture", "bundle": "local.other",
                                   "key": rec["id"], "ref": "other-ref"}) + "\n")
    filer = CloudFakeFiler()
    seen = bl.load_seen()
    assert not bl.already_filed(filer, cfg["apps"][0], rec, {"dir": "phone"}, {"keys": []},
                                "keys", seen, cloud_summary())


def test_legacy_inbox_lines_still_recover_by_name(listener_state):
    cfg, rec, _ = cloud_fixture(listener_state)
    bl.INBOX.write_text(json.dumps({"app": "fixture", "key": rec["id"], "ref": "legacy-ref"}) + "\n")
    seen = bl.load_seen()
    filer = CloudFakeFiler()
    assert bl.already_filed(filer, cfg["apps"][0], rec, {"dir": "phone"}, {"keys": []},
                            "keys", seen, cloud_summary())
    assert not filer.calls


def test_tracker_acknowledgement_survives_failed_inbox_append_and_retries_without_refiling(listener_state, monkeypatch):
    cfg, rec, _ = cloud_fixture(listener_state)
    filer, seen = CloudFakeFiler(), {}
    inbox = bl.INBOX
    monkeypatch.setattr(bl, "INBOX", listener_state)  # directory cannot be appended to
    summary = cloud_summary()
    bl.poll_cloud_reports(cfg, seen, filer, summary, False)
    assert len(filer.calls) == 1 and summary["errors"] == 1
    assert seen["_deliveries"][rec["bundle"] + ":" + rec["id"]]["inbox"] is False
    monkeypatch.setattr(bl, "INBOX", inbox)
    bl.poll_cloud_reports(cfg, seen, filer, cloud_summary(), False)
    assert len(filer.calls) == 1
    assert json.loads(inbox.read_text())["key"] == rec["id"]


def test_cloud_issue_body_names_actual_nested_log_path(listener_state):
    cfg, rec, _ = cloud_fixture(listener_state)
    rec["log"] = "logs/nested/session.jsonl"
    documents = Path(cfg["cloudkit"]["inbox"]) / rec["id"] / "Documents"
    body = bl.issue_body(rec, rec["id"], {"type": "CloudKit"}, cfg["apps"][0], documents)
    assert str(documents / rec["log"]) in body


def test_cloud_sync_exposes_index_action_without_raw_server_details(listener_state, monkeypatch):
    cfg, _, _ = cloud_fixture(listener_state)
    output = json.dumps({"event": "cloudkit_sync", "ok": False, "code": 12,
                         "reason": "missing_query_index", "hint": "private container details",
                         "message": "private account details"})
    monkeypatch.setattr(bl, "run", lambda *args, **kwargs: (1, output, "raw private CKError"))
    health, summary = {}, cloud_summary()
    bl.sync_cloudkit(cfg, summary, health)
    assert health["cloudkit"]["ok"] is False
    assert health["cloudkit"]["code"] == 12
    assert health["cloudkit"]["reason"] == "missing_query_index"
    assert "recordName Queryable" in health["cloudkit"]["action"]
    assert summary["errors"] == 1
    events = [json.loads(line) for line in bl.LOG.read_text().splitlines()]
    assert events[-1]["code"] == 12 and events[-1]["reason"] == "missing_query_index"
    assert "private" not in bl.LOG.read_text()


@pytest.mark.parametrize("code, reason", [(True, "missing_query_index"), ("12", ["private"]),
                                          (999999999, {"private": "data"}), (12, "private reason")])
def test_cloud_sync_drops_untrusted_diagnostics(listener_state, monkeypatch, code, reason):
    cfg, _, _ = cloud_fixture(listener_state)
    output = json.dumps({"event": "cloudkit_sync", "ok": False, "code": code, "reason": reason})
    monkeypatch.setattr(bl, "run", lambda *args, **kwargs: (1, output, "private stderr"))
    health = {}
    bl.sync_cloudkit(cfg, cloud_summary(), health)
    assert health["cloudkit"]["ok"] is False
    assert "action" not in health["cloudkit"]
    assert "private" not in bl.LOG.read_text()


def test_cloud_sync_success_does_not_keep_failure_diagnostics(listener_state, monkeypatch):
    cfg, _, _ = cloud_fixture(listener_state)
    output = '\n'.join(json.dumps(e) for e in (
        {"event": "cloudkit_sync", "ok": False, "code": 12, "reason": "missing_query_index"},
        {"event": "cloudkit_sync", "ok": True, "downloaded": 0}))
    monkeypatch.setattr(bl, "run", lambda *args, **kwargs: (0, output, ""))
    health = {}
    bl.sync_cloudkit(cfg, cloud_summary(), health)
    assert health["cloudkit"]["ok"] is True
    assert "code" not in health["cloudkit"] and "action" not in health["cloudkit"]


@pytest.mark.parametrize("lose_seen_store", [False, True])
def test_device_first_then_cloudkit_keeps_one_tracker_and_one_inbox_line(listener_state, lose_seen_store):
    cfg, rec, _ = cloud_fixture(listener_state)
    filer = CloudFakeFiler()
    seen, summary = {}, cloud_summary()
    device_entry = {"keys": []}
    # Exercise the actual device delivery/receipt write rather than seed a claimed success.
    assert bl.deliver(filer, cfg["apps"][0], rec, {"dir": "phone", "type": "iPhone"},
                      listener_state, device_entry, "keys", seen, summary)
    assert len(filer.calls) == 1
    assert len(bl.INBOX.read_text().splitlines()) == 1
    if lose_seen_store:
        bl.SEEN.unlink()
    seen = bl.load_seen()
    bl.poll_cloud_reports(cfg, seen, filer, summary, False)
    bl.poll_cloud_reports(cfg, seen, filer, summary, False)
    assert len(filer.calls) == 1
    lines = [json.loads(line) for line in bl.INBOX.read_text().splitlines()]
    assert len(lines) == 1 and lines[0]["key"] == rec["id"]
    assert lines[0]["ref"] == "synthetic-ref"
    assert summary["filed"] == 1 and summary["errors"] == 0
