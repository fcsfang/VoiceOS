#!/usr/bin/env python3
"""Synthetic association process-crash and migration checks; no external services."""
import argparse
import json
import os
import subprocess
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument('--root', required=True, type=Path)
parser.add_argument('--binary', type=Path, default=Path('.build/debug/voiceos-check'))
args = parser.parse_args()
if args.root.exists():
    parser.error('Use a fresh isolated root')
args.root.mkdir(parents=True, mode=0o700)
binary = str(args.binary.resolve())

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
    run('association-fixture', root, crash=checkpoint)
    recovered = run('association-fixture', root)
    completed = checkpoint == 'associationCommitted'
    assert recovered['state'] == ('completed' if completed else 'unknown')
    assert recovered['validity'] == 'current'
    assert recovered['proposals'] == (1 if completed else 0)
    assert recovered['port_calls'] == 0 and recovered['integrity']
    assert recovered['claims'] == recovered['actions'] == recovered['network_calls'] == 0
    assert recovered['usage'] == ({'input_tokens': 17, 'output_tokens': 23} if completed else {})
    assert run('association-fixture', root) == recovered
    package, target = args.root / (checkpoint + '-package'), args.root / (checkpoint + '-restored')
    run('export', root, package)
    manifest = json.loads((package / 'manifest.json').read_text())
    assert manifest['version'] == 20 and manifest['databaseSchema'] == 21
    assert (package / 'expression_association_attempts.jsonl').exists()
    run('restore', target, package)
    restored = run('association-fixture', target)
    assert restored == dict(recovered, validity='frozen')
    checks.append({'checkpoint': checkpoint, 'state': recovered['state'],
                   'replay_port_calls': 0, 'restored_validity': 'frozen',
                   'partial_claims_or_actions': False, 'usage': recovered['usage']})
report = {'date': '2026-10-11', 'schema': 21, 'package_version': 20,
          'synthetic_only': True, 'process_crashes': checks, 'portable_round_trips': 3,
          'cloud_calls': 0, 'microphone_calls': 0, 'external_task_writes': 0}
(args.root / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
print(json.dumps(report, indent=2))
