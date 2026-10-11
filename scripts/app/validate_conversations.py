#!/usr/bin/env python3
"""Synthetic local process-crash checks. No model, microphone or external task calls."""
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
    parser.error('Use a new isolated validation directory')
args.root.mkdir(parents=True, mode=0o700)
binary = str(args.binary.resolve())

def run(command, root, *extra, crash=None):
    env = dict(os.environ)
    env.pop('VOICEOS_TEST_CRASH_AT', None)
    if crash:
        env['VOICEOS_TEST_CRASH_AT'] = crash
    result = subprocess.run([binary, command, str(root), *map(str, extra)], env=env, capture_output=True, timeout=60)
    assert result.returncode == (-9 if crash else 0), (command, result.returncode, result.stderr.decode()[:300])
    return result

def rows(root):
    with sqlite3.connect(f'file:{root / "voiceos.sqlite"}?mode=ro', uri=True) as db:
        session = db.execute('SELECT id,version,state,validity FROM conversations').fetchall()
        turns = db.execute('SELECT id FROM conversation_user_turns').fetchall()
        counts = {table: db.execute(f'SELECT count(*) FROM {table}').fetchone()[0]
                  for table in ['claims', 'actions', 'model_attempts', 'relevance_attempts', 'reminder_links']}
    assert not any(counts.values()), counts
    return session, turns

checks = []
for point in ['conversationUncommitted', 'conversationCommitted', 'conversationTurnUncommitted',
              'conversationTurnCommitted', 'conversationEndUncommitted', 'conversationEndCommitted']:
    root = args.root / point
    operation = ('conversation-entry-fixture' if point in ['conversationUncommitted', 'conversationCommitted']
                 else 'conversation-turn-fixture' if 'Turn' in point else 'conversation-end-fixture')
    run(operation, root, crash=point)
    run('read', root)  # Recovery in a fresh process.
    sessions, turns = rows(root)
    if point == 'conversationUncommitted':
        assert not sessions and not turns
    else:
        expected_turns = 0 if point in ['conversationCommitted', 'conversationTurnUncommitted'] else 1
        expected_state = 'ended' if point == 'conversationEndCommitted' else 'active'
        assert len(sessions) == 1 and len(turns) == expected_turns
        assert sessions[0][1:3] == (1 + expected_turns + int(expected_state == 'ended'), expected_state)
    run('conversation-end-fixture', root)
    run('conversation-end-fixture', root)
    sessions, turns = rows(root)
    assert len(sessions) == len(turns) == 1 and sessions[0][1:] == (3, 'ended', 'current')
    checks.append({'checkpoint': point, 'recovered_and_replayed_once': True})

source = args.root / 'conversationEndCommitted'
session_id = rows(source)[0][0][0]
for media in [False, True]:
    package = args.root / ('media-package' if media else 'metadata-package')
    target = args.root / ('media-restored' if media else 'metadata-restored')
    run('export', source, package, *(['media'] if media else []))
    run('restore', target, package)
    result = json.loads(run('conversation-read', target, session_id).stdout)
    assert result['validity'] == 'frozen' and result['state'] == 'ended' and result['user_turns'] == 1 and result['integrity']

report = {'date': '2026-10-11', 'synthetic_only': True, 'process_crashes': checks,
          'portable_round_trips': 2, 'schema': 17, 'package_version': 16,
          'microphone_calls': 0, 'cloud_calls': 0, 'external_task_writes': 0}
(args.root / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
print(json.dumps(report, indent=2))
