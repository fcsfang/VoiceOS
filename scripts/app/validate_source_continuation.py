#!/usr/bin/env python3
"""Kill a synthetic cognition-to-association chain and explicitly continue without replay."""
import argparse
import json
import os
from pathlib import Path
import subprocess

parser = argparse.ArgumentParser()
parser.add_argument('--root', required=True, type=Path)
args = parser.parse_args()
if args.root.exists():
    parser.error('Use a fresh isolated root')
args.root.mkdir(parents=True, mode=0o700)
binary = str(Path('.build/debug/voiceos-check').resolve())

def run(command, root, *extra, crash=None):
    env = dict(os.environ)
    env.pop('VOICEOS_TEST_CRASH_AT', None)
    if crash:
        env['VOICEOS_TEST_CRASH_AT'] = crash
    result = subprocess.run([binary, command, str(root), *map(str, extra)], env=env, capture_output=True, timeout=30)
    assert result.returncode == (-9 if crash else 0), (command, result.returncode, result.stderr.decode()[:300])
    return None if crash else json.loads(result.stdout)

checks = []
for checkpoint in ['modelReserved', 'claimsUncommitted', 'claimsCommitted', 'associationReserved', 'associationUncommitted', 'associationCommitted']:
    root = args.root / checkpoint
    run('source-continuation-fixture', root, crash=checkpoint)
    result = run('source-continuation-fixture', root)
    has_claims = checkpoint not in ['modelReserved', 'claimsUncommitted']
    assert result['claims'] == result['questions'] == int(has_claims)
    assert result['cognition_calls'] == result['actions'] == result['cloud_calls'] == 0
    assert result['integrity']
    assert result['understanding_state'] == ('completed' if has_claims else 'unknown')
    assert result['association_state'] == ('not_run' if not has_claims else 'completed' if checkpoint in ['claimsCommitted', 'associationCommitted'] else 'unknown')
    assert result['association_calls'] == int(checkpoint == 'claimsCommitted')
    again = run('source-continuation-fixture', root)
    assert again == dict(result, association_calls=0)
    package, restored = args.root / (checkpoint + '-package'), args.root / (checkpoint + '-restored')
    run('export', root, package); run('restore', restored, package); run('read', restored)
    replay = run('source-continuation-fixture', restored)
    assert replay['cognition_calls'] == replay['association_calls'] == 0
    assert replay['claims'] == replay['questions'] == int(has_claims)
    checks.append({'checkpoint': checkpoint, 'understanding': result['understanding_state'], 'association': result['association_state'], 'continued_missing_association_once': checkpoint == 'claimsCommitted', 'replayed_cognition': False, 'restored_calls': 0})
print(json.dumps({'synthetic_only': True, 'process_kills': 6, 'portable_round_trips': 6, 'checks': checks,
                  'cloud_calls': 0, 'microphone_calls': 0, 'external_task_writes': 0}, indent=2))
