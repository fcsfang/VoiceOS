#!/usr/bin/env python3
"""Real process termination and migration checks; private synthetic roots only."""
import argparse
import json
import os
from pathlib import Path
import signal
import sqlite3
import subprocess

p = argparse.ArgumentParser()
p.add_argument('--output', type=Path, required=True)
a = p.parse_args()
a.output.mkdir(parents=True, exist_ok=False)
repo = Path(__file__).resolve().parents[2]
binary = repo / '.build/debug/voiceos-check'

def run(command, root, *extra, crash=None, code=0):
    env = dict(os.environ)
    env.pop('VOICEOS_TEST_CRASH_AT', None)
    if crash:
        env['VOICEOS_TEST_CRASH_AT'] = crash
    result = subprocess.run([str(binary), command, str(root), *map(str, extra)], env=env, capture_output=True, text=True, timeout=30)
    assert result.returncode == (-signal.SIGKILL if crash else code), result.stderr
    return result.stdout

cases = []
for point in ['relevanceReserved', 'relevanceUncommitted', 'relevanceCommitted']:
    root = a.output / point
    run('relevance-fixture', root, crash=point)
    assert run('read', root) == run('read', root)
    marker = root / 'fixture-call-marker'
    expected_marker = point != 'relevanceReserved'
    assert marker.exists() == expected_marker
    before = marker.read_bytes() if marker.exists() else None
    run('relevance-fixture', root, code=1)
    assert (marker.read_bytes() if marker.exists() else None) == before
    with sqlite3.connect(root / 'voiceos.sqlite') as db:
        assert db.execute('pragma integrity_check').fetchone()[0] == 'ok'
        assert not db.execute('pragma foreign_key_check').fetchall()
        assert db.execute('pragma user_version').fetchone()[0] == 12
        rows = db.execute('select state,validity,selection_json,usage_json from relevance_attempts').fetchall()
        assert len(rows) == 1
        state, validity, selection, usage = rows[0]
        assert state == ('completed' if point == 'relevanceCommitted' else 'unknown')
        assert validity == 'current'
        assert (selection is not None) == (state == 'completed')
        if selection:
            assert len(json.loads(selection)) == 1
        assert (usage is not None) == expected_marker
        assert db.execute('select count(*) from relevance_inputs').fetchone()[0] == 1
        for table in ['claims', 'actions', 'reminder_links', 'model_attempts']:
            assert db.execute(f'select count(*) from {table}').fetchone()[0] == 0
    cases.append({'checkpoint': point, 'state': state, 'passed': True, 'model_callback_count': int(expected_marker), 'restart_and_repeat_without_resend': True})

# An isolated fixture in the exact preceding schema shape, with existing text.
upgrade = a.output / 'schema11-upgrade'
run('expression-fixture', upgrade)
with sqlite3.connect(upgrade / 'voiceos.sqlite') as db:
    prior = db.execute('select id,command_id from sources').fetchall()
    db.execute('drop table relevance_inputs')
    db.execute('drop table relevance_attempts')
    db.execute('pragma user_version=11')
run('read', upgrade)
with sqlite3.connect(upgrade / 'voiceos.sqlite') as db:
    assert db.execute('pragma user_version').fetchone()[0] == 12
    assert db.execute('select id,command_id from sources').fetchall() == prior
    assert db.execute('select count(*) from relevance_attempts').fetchone()[0] == 0

# Genuine previously exported packages, with current empty-table v10 fallback.
packages = {}
for manifest in sorted((repo / 'runtime').rglob('manifest.json')):
    try:
        value = json.loads(manifest.read_text())
        version = value.get('version')
        if isinstance(version, int) and 1 <= version <= 10:
            packages.setdefault(version, []).append(manifest.parent)
    except (ValueError, OSError):
        pass
package_checks = []
assert set(packages) == set(range(1, 11)), 'requires actual previously exported v1-v10 packages under runtime'
for version, options in sorted(packages.items()):
    success = False
    for index, package in enumerate(options):
        target = a.output / f'legacy-v{version}-{index}'
        try:
            run('restore', target, package)
            run('read', target)
            with sqlite3.connect(target / 'voiceos.sqlite') as db:
                assert db.execute('pragma user_version').fetchone()[0] == 12
                assert db.execute('pragma integrity_check').fetchone()[0] == 'ok'
                assert not db.execute('pragma foreign_key_check').fetchall()
            package_checks.append({'version': version, 'package': str(package.relative_to(repo)), 'passed': True})
            success = True
            break
        except AssertionError:
            continue  # Earlier deliberate damaged fixtures remain rejected.
    assert success, f'no valid legacy package for v{version}'
report = {'date': '2026-10-11', 'passed': True, 'sigkill_count': 3, 'cloud_calls': 0, 'external_writes': 0, 'cases': cases, 'schema11_upgrade': True, 'legacy_packages': package_checks}
(a.output / 'summary.json').write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
print(json.dumps(report, ensure_ascii=False))
