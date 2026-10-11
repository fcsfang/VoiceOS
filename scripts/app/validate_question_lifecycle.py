#!/usr/bin/env python3
"""Offline typed-question atomicity and portable state; synthetic input only."""
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

def counts(root):
    with sqlite3.connect(root / 'voiceos.sqlite') as db:
        return dict(zip(['claims', 'questions', 'revisions'], [db.execute(f'SELECT COUNT(*) FROM {table}').fetchone()[0] for table in ['claims', 'questions', 'question_revisions']]))

checks = []
for checkpoint in ['claimsUncommitted', 'claimsCommitted', 'questionUncommitted', 'questionCommitted']:
    root = args.root / checkpoint
    if checkpoint.startswith('claims'):
        run('typed-cognition-fixture', root, crash=checkpoint)
        recovered = run('typed-cognition-fixture', root)
        n = 1 if checkpoint == 'claimsCommitted' else 0
        assert recovered['question_candidates'] == n and recovered['questions'] == n
        assert counts(root) == {'claims': n, 'questions': n, 'revisions': 0}
    else:
        run('typed-cognition-fixture', root)
        run('question-close-fixture', root, crash=checkpoint)
        before = counts(root)
        assert before['revisions'] == (1 if checkpoint == 'questionCommitted' else 0)
        recovered = run('question-close-fixture', root)
        again = run('question-close-fixture', root)
        assert recovered == again
        assert recovered['version'] == 2 and recovered['status'] == 'closed' and recovered['revisions'] == 1
    assert recovered['integrity'] and recovered['network_calls'] == 0 and recovered['external_task_writes'] == 0
    package, restored = args.root / (checkpoint + '-package'), args.root / (checkpoint + '-restored')
    run('export', root, package)
    manifest = json.loads((package / 'manifest.json').read_text())
    assert manifest['version'] == 23 and manifest['databaseSchema'] == 24
    run('restore', restored, package)
    run('read', restored)
    assert counts(root) == counts(restored)
    with sqlite3.connect(restored / 'voiceos.sqlite') as db:
        assert db.execute("SELECT COUNT(*) FROM questions WHERE validity!='frozen'").fetchone()[0] == 0
    checks.append({'checkpoint': checkpoint, 'recovered_counts': counts(root), 'restored_counts': counts(restored), 'restored_history_frozen': True})
print(json.dumps({'synthetic_only': True, 'process_kills': len(checks), 'portable_round_trips': len(checks), 'checks': checks, 'cloud_calls': 0, 'microphone_calls': 0, 'external_task_writes': 0}, indent=2))
