"""Synthetic portable JSON/asset and SQLite backup experiment, not the final schema."""
import copy
import hashlib
import json
from pathlib import Path
import sqlite3
import tempfile


def sha(data):
    return hashlib.sha256(data).hexdigest()


def serialize(value):
    return json.dumps(value, ensure_ascii=False, sort_keys=True).encode("utf-8")


def validate(root):
    manifest = json.loads((root / "manifest.json").read_bytes())
    if manifest["format_version"] != 1:
        raise ValueError("unsupported-version")
    for name, expected in manifest["files"].items():
        path = root / name
        if Path(name).is_absolute() or not path.resolve().is_relative_to(root.resolve()):
            raise ValueError("unsafe-path")
        if not path.is_file() or sha(path.read_bytes()) != expected:
            raise ValueError("missing-or-corrupt")
    if "records.json" not in manifest["files"]:
        raise ValueError("missing-records")
    records = json.loads((root / "records.json").read_bytes())
    identities = {item["id"] for item in records}
    if len(identities) != len(records):
        raise ValueError("duplicate-identity")
    for item in records:
        if any(reference not in identities for reference in item["references"]):
            raise ValueError("dangling-reference")
        if item["type"] == "Source":
            asset = item["asset"]
            if manifest["asset_mode"] == "bundled" and asset not in manifest["files"]:
                raise ValueError("missing-asset")
            if manifest["asset_mode"] not in ("bundled", "reference-only"):
                raise ValueError("unsupported-asset-mode")
    return records


def main():
    fixture = [
        {"id": "source-1", "type": "Source", "references": [], "only_local": True,
         "asset": "assets/source-1.raw", "asset_sha256": sha(b"synthetic bytes")},
        {"id": "event-1", "type": "ThoughtEvent", "references": ["source-1"], "text": "我还没有验证。"},
        {"id": "claim-1", "type": "Claim", "references": ["event-1"], "ownership": "user-tentative",
         "evidence": "unverified", "validity": "superseded", "source_span": [0, 7]},
        {"id": "revision-1", "type": "Revision", "references": ["claim-1", "event-1"], "reason": "用户纠正归属"},
        {"id": "task-1", "type": "Task", "references": ["claim-1"], "state": "completed",
         "external_mapping": {"provider": "simulated", "id": "external-1", "needs_reconciliation": True}},
        {"id": "outcome-1", "type": "Outcome", "references": ["task-1", "event-1"], "text": "合成结果"},
        {"id": "relation-1", "type": "Relation", "references": ["claim-1", "outcome-1"], "state": "invalidated"},
    ]
    checks = {}
    with tempfile.TemporaryDirectory(prefix="voiceos-migration-probe-") as scratch:
        root = Path(scratch)
        source = sqlite3.connect(root / "source.sqlite3")
        source.execute("PRAGMA journal_mode=WAL")
        source.execute("CREATE TABLE records(id TEXT PRIMARY KEY, payload BLOB)")
        source.executemany("INSERT INTO records VALUES (?,?)", [(item["id"], serialize(item)) for item in fixture])
        source.commit()
        backup = sqlite3.connect(root / "backup.sqlite3")
        source.backup(backup)  # Live connection + WAL snapshot, not bare-main-file copy.
        checks["live_backup_integrity"] = backup.execute("PRAGMA integrity_check").fetchone()[0] == "ok"
        checks["live_backup_records_exact"] = backup.execute("SELECT * FROM records ORDER BY id").fetchall() == source.execute("SELECT * FROM records ORDER BY id").fetchall()
        backup.close()
        package = root / "package"
        (package / "assets").mkdir(parents=True)
        (package / "records.json").write_bytes(serialize(fixture))
        (package / "assets/source-1.raw").write_bytes(b"synthetic bytes")
        manifest = {"format_version": 1, "asset_mode": "bundled", "files": {
            name: sha((package / name).read_bytes()) for name in ("records.json", "assets/source-1.raw")}}
        (package / "manifest.json").write_bytes(serialize(manifest))
        restored_records = validate(package)
        restored = sqlite3.connect(root / "restored.sqlite3")
        restored.execute("CREATE TABLE records(id TEXT PRIMARY KEY, payload BLOB)")
        restored.executemany("INSERT INTO records VALUES (?,?)", [(item["id"], serialize(item)) for item in restored_records])
        restored.commit()
        checks["portable_restore_exact"] = restored.execute("SELECT * FROM records ORDER BY id").fetchall() == source.execute("SELECT * FROM records ORDER BY id").fetchall()
        checks["permissions_history_relations_retained"] = restored_records == fixture
        restored.close()
        source.close()
        base_records = serialize(fixture)

        def rejected(name, transform):
            (package / "records.json").write_bytes(base_records)
            (package / "assets/source-1.raw").write_bytes(b"synthetic bytes")
            altered = copy.deepcopy(manifest)
            transform(altered)
            (package / "manifest.json").write_bytes(serialize(altered))
            try:
                validate(package)
                checks[name] = False
            except ValueError:
                checks[name] = True

        rejected("corrupt_records_rejected", lambda _: (package / "records.json").write_bytes(b"tampered"))
        rejected("missing_asset_rejected", lambda _: (package / "assets/source-1.raw").unlink())
        rejected("unsupported_version_rejected", lambda m: m.update(format_version=99))
        rejected("path_escape_rejected", lambda m: m["files"].update({"../escape": "unused"}))

        def dangling(m):
            changed = copy.deepcopy(fixture)
            changed[1]["references"] = ["missing-source"]
            (package / "records.json").write_bytes(serialize(changed))
            m["files"]["records.json"] = sha(serialize(changed))

        rejected("dangling_reference_rejected", dangling)
        (package / "records.json").write_bytes(base_records)
        (package / "assets/source-1.raw").unlink()
        reference_only = {"format_version": 1, "asset_mode": "reference-only", "files": {"records.json": sha(base_records)}}
        (package / "manifest.json").write_bytes(serialize(reference_only))
        checks["reference_only_explicitly_supported"] = validate(package) == fixture
    print(json.dumps({"probe": "portable-snapshot-v1", "fixture_entity_count": len(fixture), "checks": checks,
                      "scope": "synthetic records only; tentative export layout; no encrypted backups, schema upgrades, large media, production deletion or external restore writes"}, indent=2))
    if not all(checks.values()):
        raise SystemExit(1)


if __name__ == "__main__":
    main()
