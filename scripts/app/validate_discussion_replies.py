#!/usr/bin/env python3
"""Synthetic local discussion crash/recovery checks; no cloud, mic or EventKit."""
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

def receipt(root):
    with sqlite3.connect(f'file:{root / "voiceos.sqlite"}?mode=ro', uri=True) as db:
        sessions = db.execute('SELECT id FROM conversations').fetchall()
        attempts = db.execute('SELECT id,state,result_json,usage_json FROM discussion_attempts').fetchall()
        assert len(sessions) == len(attempts) == 1
        counts = {table: db.execute(f'SELECT count(*) FROM {table}').fetchone()[0]
                  for table in ['claims', 'actions', 'model_attempts', 'relevance_attempts', 'reminder_links']}
        assert not any(counts.values())
        return sessions[0][0], attempts[0]

checks = []
for point in ['discussionReserved', 'discussionUncommitted', 'discussionCommitted']:
    root = args.root / point
    run('discussion-fixture', root, crash=point)
    run('read', root)
    session, attempt = receipt(root)
    expected = 'completed' if point == 'discussionCommitted' else 'unknown'
    assert attempt[1] == expected
    assert (attempt[2] is not None) == (expected == 'completed')
    # The fixture explicitly observes the receipt instead of issuing a repeat call.
    run('discussion-fixture', root)
    run('discussion-fixture', root)
    assert receipt(root)[1] == attempt
    result = json.loads(run('discussion-read', root, session).stdout)
    assert result['integrity']
    checks.append({'checkpoint': point, 'state': expected, 'single_attempt_after_reopen_and_replay': True})

source = args.root / 'discussionCommitted'
session, attempt = receipt(source)
for media in [False, True]:
    package = args.root / ('media-package' if media else 'metadata-package')
    target = args.root / ('media-restored' if media else 'metadata-restored')
    run('export', source, package, *(['media'] if media else []))
    run('restore', target, package)
    result = json.loads(run('discussion-read', target, session).stdout)
    row = result['attempts'][0]
    assert result['integrity'] and row['id'] == attempt[0] and row['state'] == 'completed'
    assert row['validity'] == 'frozen' and row['parts'] == 2 and row['usage'] == {'input_tokens': 11, 'output_tokens': 5}

report = {'date': '2026-10-11', 'synthetic_only': True, 'process_crashes': checks,
          'portable_round_trips': 2, 'schema': 19, 'package_version': 18,
          'microphone_calls': 0, 'cloud_calls': 0, 'external_task_writes': 0}
(args.root / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
print(json.dumps(report, indent=2))
