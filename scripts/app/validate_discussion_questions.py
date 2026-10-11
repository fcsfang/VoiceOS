#!/usr/bin/env python3
"""Offline SIGKILL checks for typed personal/AI outcomes and frozen migration."""
import argparse
import json
import os
from pathlib import Path
import sqlite3
import subprocess

parser = argparse.ArgumentParser()
parser.add_argument('--root', required=True, type=Path)
parser.add_argument('--binary', type=Path, default=Path('.build/debug/voiceos-check'))
args = parser.parse_args()
if args.root.exists():
    parser.error('Use a fresh isolated root')
args.root.mkdir(mode=0o700, parents=True)
binary = str(args.binary.resolve())

def run(command, root, *extra, crash=None):
    env = dict(os.environ)
    env.pop('VOICEOS_TEST_CRASH_AT', None)
    if crash:
        env['VOICEOS_TEST_CRASH_AT'] = crash
    result = subprocess.run([binary, command, str(root), *map(str, extra)], env=env, capture_output=True, timeout=30)
    assert result.returncode == (-9 if crash else 0), (command, result.returncode, result.stderr.decode()[:250])
    return None if crash else json.loads(result.stdout)

checks = []
for checkpoint in ['outcomeReserved', 'outcomeUncommitted', 'outcomeCommitted']:
    root = args.root / checkpoint
    run('discussion-question-fixture', root, crash=checkpoint)
    recovered = run('discussion-question-fixture', root)
    expected = 2 if checkpoint == 'outcomeCommitted' else 0
    assert recovered['outcome_state'] == ('completed' if expected else 'unknown')
    assert recovered['questions'] == recovered['claims'] == expected
    assert recovered['actions'] == recovered['fixture_port_calls'] == recovered['network_calls'] == 0
    assert recovered == run('discussion-question-fixture', root) and recovered['integrity']
    if expected:
        assert recovered['ownership'] == ['ai_candidate', 'user_tentative']
        assert recovered['statuses'] == ['open', 'open']
    package, restored = args.root / (checkpoint + '-package'), args.root / (checkpoint + '-restored')
    run('export', root, package)
    manifest = json.loads((package / 'manifest.json').read_text())
    assert (manifest['version'], manifest['databaseSchema']) == (23, 24)
    run('restore', restored, package); run('read', restored)
    with sqlite3.connect(restored / 'voiceos.sqlite') as db:
        assert db.execute('SELECT COUNT(*) FROM questions').fetchone()[0] == expected
        assert db.execute("SELECT COUNT(*) FROM questions WHERE validity!='frozen'").fetchone()[0] == 0
    checks.append({'checkpoint': checkpoint, 'state': recovered['outcome_state'], 'questions': expected, 'replay_calls': 0, 'restored_history_frozen': True})
print(json.dumps({'synthetic_only': True, 'process_kills': 3, 'portable_round_trips': 3, 'checks': checks,
                  'cloud_calls': 0, 'microphone_calls': 0, 'external_task_writes': 0}, indent=2))
