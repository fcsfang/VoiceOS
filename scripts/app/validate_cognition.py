#!/usr/bin/env python3
"""Local synthetic proposals against the app Core. No model/network/reminder calls."""
import argparse, json, os, signal, sqlite3, subprocess
from pathlib import Path
p = argparse.ArgumentParser()
p.add_argument('--package', type=Path, required=True, help='authorized existing package with nonempty transcript')
p.add_argument('--output', type=Path, required=True)
a = p.parse_args(); a.output.mkdir(parents=True, exist_ok=False)
binary = Path(__file__).resolve().parents[2] / '.build/debug/voiceos-check'
def run(command, root, crash=None, extra=()):
    env = dict(os.environ); env.pop('VOICEOS_TEST_CRASH_AT', None)
    if crash: env['VOICEOS_TEST_CRASH_AT'] = crash
    r = subprocess.run([str(binary), command, str(root), *map(str,extra)], env=env, capture_output=True, text=True, timeout=90)
    assert r.returncode == (-signal.SIGKILL if crash else 0), r.stderr
    return r.stdout
cases = []
for checkpoint in ['modelReserved','claimsUncommitted','claimsCommitted','correctionUncommitted','correctionCommitted','policyUncommitted','policyCommitted']:
    root = a.output / checkpoint
    run('restore', root, extra=[a.package.resolve()])
    with sqlite3.connect(root/'voiceos.sqlite') as db:
        assert db.execute('select count(*) from contexts').fetchone()[0] == 0, 'Use an input-only package without existing cognitive receipts.'
    if checkpoint.startswith(('correction','policy')):
        run('cognition-fixture', root)
    before = sqlite3.connect(root/'voiceos.sqlite').execute('select version from transcripts').fetchone()[0]
    command = 'policy-fixture' if checkpoint.startswith('policy') else ('correction-fixture' if checkpoint.startswith('correction') else 'cognition-fixture')
    run(command, root, crash=checkpoint)
    assert run('read', root) == run('read', root)
    with sqlite3.connect(root/'voiceos.sqlite') as db:
        assert db.execute('pragma integrity_check').fetchone()[0] == 'ok'
        assert not db.execute('pragma foreign_key_check').fetchall()
        attempts = db.execute('select state from model_attempts').fetchall()
        claims = db.execute('select validity from claims').fetchall()
        context = db.execute('select state from contexts').fetchall()
        version = db.execute('select version from transcripts').fetchone()[0]
        if checkpoint in ['modelReserved','claimsUncommitted']:
            assert attempts == [('unknown',)] and claims == [] and context == [('current',)]
        elif checkpoint == 'claimsCommitted':
            assert attempts == [('completed',)] and claims == [('current',)]
        elif checkpoint == 'correctionUncommitted':
            assert claims == [('current',)] and context == [('current',)] and version == before
        elif checkpoint == 'correctionCommitted':
            assert claims == [('frozen',)] and context == [('stale',)] and version == before+1
        elif checkpoint == 'policyUncommitted':
            assert claims == [('current',)] and context == [('current',)]
            assert db.execute('select local_only,policy_version from sources').fetchone() == (1,1)
            assert db.execute('select count(*) from source_policy_revisions').fetchone()[0] == 0
        else:
            assert claims == [('frozen',)] and context == [('stale',)]
            assert db.execute('select local_only,policy_version from sources').fetchone() == (0,2)
            assert db.execute('select count(*) from source_policy_revisions').fetchone()[0] == 1
    cases.append({'checkpoint':checkpoint,'passed':True,'stable_reopen':True})
report = {'date':'2026-10-10','synthetic_local_proposals':True,'count':len(cases),'sigkill_count':len(cases),'passed':True,'cases':cases,'network_calls':0,'external_actions':0}
(a.output/'summary.json').write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')
print(json.dumps({'count':len(cases),'passed':True}))
