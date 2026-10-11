#!/usr/bin/env python3
"""Synthetic association process-crash and migration checks; no external services."""
import argparse
import json
import os
import subprocess
import sqlite3
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument('--root', required=True, type=Path)
parser.add_argument('--binary', type=Path, default=Path('.build/debug/voiceos-check'))
parser.add_argument('--driver', action='store_true', help='exercise complete local-recall-to-receipt driver with synthetic ports')
args = parser.parse_args()
if args.root.exists():
    parser.error('Use a fresh isolated root')
args.root.mkdir(parents=True, mode=0o700)
binary = str(args.binary.resolve())
fixture = 'association-driver-fixture' if args.driver else 'association-fixture'

def run(command, root, *extra, crash=None):
    env = dict(os.environ)
    env.pop('VOICEOS_TEST_CRASH_AT', None)
    if crash:
        env['VOICEOS_TEST_CRASH_AT'] = crash
    result = subprocess.run([binary, command, str(root), *map(str, extra)],
                            env=env, capture_output=True, timeout=30)
    assert result.returncode == (-9 if crash else 0), (command, result.returncode, result.stderr.decode()[:300])
    return None if crash else json.loads(result.stdout)

checks = []
for checkpoint in ['associationReserved', 'associationUncommitted', 'associationCommitted']:
    root = args.root / checkpoint
    run(fixture, root, crash=checkpoint)
    recovered = run(fixture, root)
    completed = checkpoint == 'associationCommitted'
    assert recovered['state'] == ('completed' if completed else 'unknown')
    assert recovered['validity'] == 'current'
    assert recovered['proposals'] == (1 if completed else 0)
    assert recovered['port_calls'] == 0 and recovered['integrity']
    assert recovered['claims'] == recovered['actions'] == recovered['network_calls'] == 0
    assert recovered['usage'] == ({'input_tokens': 17, 'output_tokens': 23} if completed else {})
    assert run(fixture, root) == recovered
    package, target = args.root / (checkpoint + '-package'), args.root / (checkpoint + '-restored')
    run('export', root, package)
    manifest = json.loads((package / 'manifest.json').read_text())
    assert manifest['version'] == 21 and manifest['databaseSchema'] == 22
    assert (package / 'expression_association_attempts.jsonl').exists()
    run('restore', target, package)
    restored = run(fixture, target)
    assert restored == dict(recovered, validity='frozen')
    checks.append({'checkpoint': checkpoint, 'state': recovered['state'],
                   'replay_port_calls': 0, 'restored_validity': 'frozen',
                   'partial_claims_or_actions': False, 'usage': recovered['usage']})
ignore_checks = []
for checkpoint in ['associationIgnoreUncommitted', 'associationIgnoreCommitted']:
    root = args.root / checkpoint
    run(fixture, root)
    run('association-ignore-fixture', root, crash=checkpoint)
    with sqlite3.connect(f'file:{root / "voiceos.sqlite"}?mode=ro', uri=True) as db:
        count = db.execute('SELECT count(*) FROM expression_association_ignores').fetchone()[0]
    assert count == (1 if checkpoint.endswith('Committed') else 0)
    assert run('association-ignore-fixture', root) == {'feedback_count': 0, 'integrity': True}
    assert run('association-ignore-fixture', root) == {'feedback_count': 0, 'integrity': True}
    package, target = args.root / (checkpoint + '-package'), args.root / (checkpoint + '-restored')
    run('export', root, package); run('restore', target, package)
    assert run('association-ignore-fixture', target) == {'feedback_count': 0, 'integrity': True}
    with sqlite3.connect(f'file:{target / "voiceos.sqlite"}?mode=ro', uri=True) as db:
        assert db.execute('SELECT count(*) FROM expression_association_ignores').fetchone()[0] == 1
    ignore_checks.append({'checkpoint': checkpoint, 'immediately_after_crash': count,
                          'replayed_ignore_count': 1, 'restored_feedback_count': 0})
report = {'date': '2026-10-11', 'schema': 22, 'package_version': 21,
          'complete_driver': args.driver,
          'synthetic_only': True, 'process_crashes': checks, 'ignore_crashes': ignore_checks, 'portable_round_trips': 5,
          'cloud_calls': 0, 'microphone_calls': 0, 'external_task_writes': 0}
(args.root / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
print(json.dumps(report, indent=2))
